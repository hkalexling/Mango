class Library
  getter dir : String, title_ids : Array(String),
    title_hash : Hash(String, Title)

  use_default

  def initialize
    register_mime_types

    @dir = Config.current.library_path
    # explicitly initialize @titles to bypass the compiler check. it will
    #   be filled with actual Titles in the `scan` call below
    @title_ids = [] of String
    @title_hash = {} of String => Title

    @entries_count = 0
    @thumbnails_count = 0

    scan_interval = Config.current.scan_interval_minutes
    if scan_interval < 1
      scan
    else
      spawn do
        loop do
          start = Time.local
          scan
          ms = (Time.local - start).total_milliseconds
          Logger.info "Scanned #{@title_ids.size} titles in #{ms}ms"
          sleep scan_interval.minutes
        end
      end
    end

    thumbnail_interval = Config.current.thumbnail_generation_interval_hours
    unless thumbnail_interval < 1
      spawn do
        loop do
          # Wait for scan to complete (in most cases)
          sleep 1.minutes
          generate_thumbnails
          sleep thumbnail_interval.hours
        end
      end
    end

    subscription_interval = Config.current
      .mangadex["subscription_update_interval_hours"].as Int32
    unless subscription_interval < 1
      spawn do
        loop do
          subscriptions = Storage.default.subscriptions
          Logger.info "Checking MangaDex for updates on " \
                      "#{subscriptions.size} subscriptions"
          added_count = 0
          subscriptions.each do |sub|
            added_count += sub.check_for_updates
          end
          Logger.info "Subscription update completed. Added #{added_count} " \
                      "chapters to the download queue"
          sleep subscription_interval.hours
        end
      end
    end
  end

  def titles
    @title_ids.map { |tid| self.get_title!(tid) }
  end

  def sorted_titles(username, opt : SortOptions? = nil)
    if opt.nil?
      opt = SortOptions.from_info_json @dir, username
    else
      TitleInfo.new @dir do |info|
        info.sort_by[username] = opt.to_tuple
        info.save
      end
    end

    # Helper function from src/util/util.cr
    sort_titles titles, opt.not_nil!, username
  end

  def deep_titles
    titles + titles.flat_map &.deep_titles
  end

  def to_json(json : JSON::Builder)
    json.object do
      json.field "dir", @dir
      json.field "titles" do
        json.raw self.titles.to_json
      end
    end
  end

  def get_title(tid)
    @title_hash[tid]?
  end

  def get_title!(tid)
    @title_hash[tid]
  end

  def scan
    unless Dir.exists? @dir
      Logger.info "The library directory #{@dir} does not exist. " \
                  "Attempting to create it"
      Dir.mkdir_p @dir
    end

    storage = Storage.new auto_close: false

    (Dir.entries @dir)
      .select { |fn| !fn.starts_with? "." }
      .map { |fn| File.join @dir, fn }
      .select { |path| File.directory? path }
      .map { |path| Title.new path, "" }
      .select { |title| !(title.entries.empty? && title.titles.empty?) }
      .sort! { |a, b| a.title <=> b.title }
      .tap { |_| @title_ids.clear }
      .each do |title|
        @title_hash[title.id] = title
        @title_ids << title.id
      end

    storage.bulk_insert_ids
    storage.close

    Logger.debug "Scan completed"
    Storage.default.mark_unavailable
  end

  def get_continue_reading_entries(username)
    cr_entries = deep_titles
      .map(&.get_last_read_entry username)
      # Select elements with type `Entry` from the array and ignore all `Nil`s
      .select(Entry)[0...ENTRIES_IN_HOME_SECTIONS]
      .map { |e|
        # Get the last read time of the entry. If it hasn't been started, get
        #   the last read time of the previous entry
        last_read = e.load_last_read username
        pe = e.previous_entry username
        if last_read.nil? && pe
          last_read = pe.load_last_read username
        end
        {
          entry:      e,
          percentage: e.load_percentage(username),
          last_read:  last_read,
        }
      }

    # Sort by by last_read, most recent first (nils at the end)
    cr_entries.sort { |a, b|
      next 0 if a[:last_read].nil? && b[:last_read].nil?
      next 1 if a[:last_read].nil?
      next -1 if b[:last_read].nil?
      b[:last_read].not_nil! <=> a[:last_read].not_nil!
    }
  end

  alias RA = NamedTuple(
    entry: Entry,
    percentage: Float64,
    grouped_count: Int32)

  def get_recently_added_entries(username)
    recently_added = [] of RA
    last_date_added = nil

    titles.flat_map(&.deep_entries_with_date_added)
      .select(&.[:date_added].> 1.month.ago)
      .sort! { |a, b| b[:date_added] <=> a[:date_added] }
      .each do |e|
        break if recently_added.size > 12
        last = recently_added.last?
        if last && e[:entry].book.id == last[:entry].book.id &&
           (e[:date_added] - last_date_added.not_nil!).abs < 1.day
          # A NamedTuple is immutable, so we have to cast it to a Hash first
          last_hash = last.to_h
          count = last_hash[:grouped_count].as(Int32)
          last_hash[:grouped_count] = count + 1
          # Setting the percentage to a negative value will hide the
          #   percentage badge on the card
          last_hash[:percentage] = -1.0
          recently_added[recently_added.size - 1] = RA.from last_hash
        else
          last_date_added = e[:date_added]
          recently_added << {
            entry:         e[:entry],
            percentage:    e[:entry].load_percentage(username),
            grouped_count: 1,
          }
        end
      end

    recently_added[0...ENTRIES_IN_HOME_SECTIONS]
  end

  def get_start_reading_titles(username)
    # Here we are not using `deep_titles` as it may cause unexpected behaviors
    # For example, consider the following nested titles:
    #   - One Puch Man
    #     - Vol. 1
    #     - Vol. 2
    # If we use `deep_titles`, the start reading section might include `Vol. 2`
    #   when the user hasn't started `Vol. 1` yet
    titles
      .select(&.load_percentage(username).== 0)
      .sample(ENTRIES_IN_HOME_SECTIONS)
      .shuffle!
  end

  def thumbnail_generation_progress
    return 0 if @entries_count == 0
    @thumbnails_count / @entries_count
  end

  def generate_thumbnails
    if @thumbnails_count > 0
      Logger.debug "Thumbnail generation in progress"
      return
    end

    Logger.info "Starting thumbnail generation"
    entries = deep_titles.flat_map(&.deep_entries).reject &.err_msg
    @entries_count = entries.size
    @thumbnails_count = 0

    # Report generation progress regularly
    spawn do
      loop do
        unless @thumbnails_count == 0
          Logger.debug "Thumbnail generation progress: " \
                       "#{(thumbnail_generation_progress * 100).round 1}%"
        end
        # Generation is completed. We reset the count to 0 to allow subsequent
        #   calls to the function, and break from the loop to stop the progress
        #   report fiber
        if thumbnail_generation_progress.to_i == 1
          @thumbnails_count = 0
          break
        end
        sleep 10.seconds
      end
    end

    entries.each do |e|
      unless e.get_thumbnail
        e.generate_thumbnail
        # Sleep after each generation to minimize the impact on disk IO
        #   and CPU
        sleep 1.seconds
      end
      @thumbnails_count += 1
    end
    Logger.info "Thumbnail generation finished"
  end
end

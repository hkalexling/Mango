require "../archive"

class Title
  getter dir : String, parent_id : String, title_ids : Array(String),
    entries : Array(Entry), title : String, id : String,
    encoded_title : String, mtime : Time, signature : UInt64

  @entry_display_name_cache : Hash(String, String)?

  def initialize(@dir : String, @parent_id)
    storage = Storage.default
    @signature = Dir.signature dir
    id = storage.get_title_id dir, signature
    if id.nil?
      id = random_str
      storage.insert_title_id({
        path:      dir,
        id:        id,
        signature: signature.to_s,
      })
    end
    @id = id
    @title = File.basename dir
    @encoded_title = URI.encode @title
    @title_ids = [] of String
    @entries = [] of Entry
    @mtime = File.info(dir).modification_time

    Dir.entries(dir).each do |fn|
      next if fn.starts_with? "."
      path = File.join dir, fn
      if File.directory? path
        title = Title.new path, @id
        next if title.entries.size == 0 && title.titles.size == 0
        Library.default.title_hash[title.id] = title
        @title_ids << title.id
        next
      end
      if is_supported_file path
        entry = Entry.new path, self
        @entries << entry if entry.pages > 0 || entry.err_msg
      end
    end

    mtimes = [@mtime]
    mtimes += @title_ids.map { |e| Library.default.title_hash[e].mtime }
    mtimes += @entries.map &.mtime
    @mtime = mtimes.max

    @title_ids.sort! do |a, b|
      compare_numerically Library.default.title_hash[a].title,
        Library.default.title_hash[b].title
    end
    sorter = ChapterSorter.new @entries.map &.title
    @entries.sort! do |a, b|
      sorter.compare a.title, b.title
    end
  end

  def to_json(json : JSON::Builder)
    json.object do
      {% for str in ["dir", "title", "id"] %}
        json.field {{str}}, @{{str.id}}
      {% end %}
      json.field "signature" { json.number @signature }
      json.field "display_name", display_name
      json.field "cover_url", cover_url
      json.field "mtime" { json.number @mtime.to_unix }
      json.field "titles" do
        json.raw self.titles.to_json
      end
      json.field "entries" do
        json.raw @entries.to_json
      end
      json.field "parents" do
        json.array do
          self.parents.each do |title|
            json.object do
              json.field "title", title.title
              json.field "id", title.id
            end
          end
        end
      end
    end
  end

  def titles
    @title_ids.map { |tid| Library.default.get_title! tid }
  end

  # Get all entries, including entries in nested titles
  def deep_entries
    return @entries if title_ids.empty?
    @entries + titles.flat_map &.deep_entries
  end

  def deep_titles
    return [] of Title if titles.empty?
    titles + titles.flat_map &.deep_titles
  end

  def parents
    ary = [] of Title
    tid = @parent_id
    while !tid.empty?
      title = Library.default.get_title! tid
      ary << title
      tid = title.parent_id
    end
    ary.reverse
  end

  # Returns a string the describes the content of the title
  #   e.g., - 3 titles and 1 entry
  #         - 4 entries
  #         - 1 title
  def content_label
    ary = [] of String
    tsize = titles.size
    esize = entries.size

    ary << "#{tsize} #{tsize > 1 ? "titles" : "title"}" if tsize > 0
    ary << "#{esize} #{esize > 1 ? "entries" : "entry"}" if esize > 0
    ary.join " and "
  end

  def tags
    Storage.default.get_title_tags @id
  end

  def add_tag(tag)
    Storage.default.add_tag @id, tag
  end

  def delete_tag(tag)
    Storage.default.delete_tag @id, tag
  end

  def get_entry(eid)
    @entries.find &.id.== eid
  end

  def display_name
    dn = @title
    TitleInfo.new @dir do |info|
      info_dn = info.display_name
      dn = info_dn unless info_dn.empty?
    end
    dn
  end

  def encoded_display_name
    URI.encode display_name
  end

  def display_name(entry_name)
    unless @entry_display_name_cache
      TitleInfo.new @dir do |info|
        @entry_display_name_cache = info.entry_display_name
      end
    end

    dn = entry_name
    info_dn = @entry_display_name_cache.not_nil![entry_name]?
    unless info_dn.nil? || info_dn.empty?
      dn = info_dn
    end
    dn
  end

  def set_display_name(dn)
    TitleInfo.new @dir do |info|
      info.display_name = dn
      info.save
    end
  end

  def set_display_name(entry_name : String, dn)
    TitleInfo.new @dir do |info|
      info.entry_display_name[entry_name] = dn
      info.save
    end
  end

  def cover_url
    url = "#{Config.current.base_url}img/icon.png"
    readable_entries = @entries.select &.err_msg.nil?
    if readable_entries.size > 0
      url = readable_entries[0].cover_url
    end
    TitleInfo.new @dir do |info|
      info_url = info.cover_url
      unless info_url.nil? || info_url.empty?
        url = File.join Config.current.base_url, info_url
      end
    end
    url
  end

  def set_cover_url(url : String)
    TitleInfo.new @dir do |info|
      info.cover_url = url
      info.save
    end
  end

  def set_cover_url(entry_name : String, url : String)
    TitleInfo.new @dir do |info|
      info.entry_cover_url[entry_name] = url
      info.save
    end
  end

  # Set the reading progress of all entries and nested libraries to 100%
  def read_all(username)
    @entries.each do |e|
      e.save_progress username, e.pages
    end
    titles.each &.read_all username
  end

  # Set the reading progress of all entries and nested libraries to 0%
  def unread_all(username)
    @entries.each &.save_progress(username, 0)
    titles.each &.unread_all username
  end

  def deep_read_page_count(username) : Int32
    load_progress_for_all_entries(username).sum +
      titles.flat_map(&.deep_read_page_count username).sum
  end

  def deep_total_page_count : Int32
    entries.sum(&.pages) +
      titles.flat_map(&.deep_total_page_count).sum
  end

  def load_percentage(username)
    deep_read_page_count(username) / deep_total_page_count
  end

  def load_progress_for_all_entries(username, opt : SortOptions? = nil,
                                    unsorted = false)
    progress = {} of String => Int32
    TitleInfo.new @dir do |info|
      progress = info.progress[username]?
    end

    if unsorted
      ary = @entries
    else
      ary = sorted_entries username, opt
    end

    ary.map do |e|
      info_progress = 0
      if progress && progress.has_key? e.title
        info_progress = [progress[e.title], e.pages].min
      end
      info_progress
    end
  end

  def load_percentage_for_all_entries(username, opt : SortOptions? = nil,
                                      unsorted = false)
    if unsorted
      ary = @entries
    else
      ary = sorted_entries username, opt
    end

    progress = load_progress_for_all_entries username, opt, unsorted
    ary.map_with_index do |e, i|
      progress[i] / e.pages
    end
  end

  # Returns the sorted entries array
  #
  # When `opt` is nil, it uses the preferred sorting options in info.json, or
  #   use the default (auto, ascending)
  # When `opt` is not nil, it saves the options to info.json
  def sorted_entries(username, opt : SortOptions? = nil)
    if opt.nil?
      opt = SortOptions.from_info_json @dir, username
    else
      TitleInfo.new @dir do |info|
        info.sort_by[username] = opt.to_tuple
        info.save
      end
    end

    case opt.not_nil!.method
    when .title?
      ary = @entries.sort { |a, b| compare_numerically a.title, b.title }
    when .time_modified?
      ary = @entries.sort { |a, b| (a.mtime <=> b.mtime).or \
        compare_numerically a.title, b.title }
    when .time_added?
      ary = @entries.sort { |a, b| (a.date_added <=> b.date_added).or \
        compare_numerically a.title, b.title }
    when .progress?
      percentage_ary = load_percentage_for_all_entries username, opt, true
      ary = @entries.zip(percentage_ary)
        .sort { |a_tp, b_tp| (a_tp[1] <=> b_tp[1]).or \
          compare_numerically a_tp[0].title, b_tp[0].title }
        .map &.[0]
    else
      unless opt.method.auto?
        Logger.warn "Unknown sorting method #{opt.not_nil!.method}. Using " \
                    "Auto instead"
      end
      sorter = ChapterSorter.new @entries.map &.title
      ary = @entries.sort do |a, b|
        sorter.compare(a.title, b.title).or \
          compare_numerically a.title, b.title
      end
    end

    ary.reverse! unless opt.not_nil!.ascend

    ary
  end

  # === helper methods ===

  # Gets the last read entry in the title. If the entry has been completed,
  #   returns the next entry. Returns nil when no entry has been read yet,
  #   or when all entries are completed
  def get_last_read_entry(username) : Entry?
    progress = {} of String => Int32
    TitleInfo.new @dir do |info|
      progress = info.progress[username]?
    end
    return if progress.nil?

    last_read_entry = nil

    sorted_entries(username).reverse_each do |e|
      if progress.has_key?(e.title) && progress[e.title] > 0
        last_read_entry = e
        break
      end
    end

    if last_read_entry && last_read_entry.finished? username
      last_read_entry = last_read_entry.next_entry username
    end

    last_read_entry
  end

  # Equivalent to `@entries.map &. date_added`, but much more efficient
  def get_date_added_for_all_entries
    da = {} of String => Time
    TitleInfo.new @dir do |info|
      da = info.date_added
    end

    @entries.each do |e|
      next if da.has_key? e.title
      da[e.title] = ctime e.zip_path
    end

    TitleInfo.new @dir do |info|
      info.date_added = da
      info.save
    end

    @entries.map { |e| da[e.title] }
  end

  def deep_entries_with_date_added
    da_ary = get_date_added_for_all_entries
    zip = @entries.map_with_index do |e, i|
      {entry: e, date_added: da_ary[i]}
    end
    return zip if title_ids.empty?
    zip + titles.flat_map &.deep_entries_with_date_added
  end

  def bulk_progress(action, ids : Array(String), username)
    selected_entries = ids
      .map { |id|
        @entries.find &.id.==(id)
      }
      .select(Entry)

    TitleInfo.new @dir do |info|
      selected_entries.each do |e|
        page = action == "read" ? e.pages : 0
        if info.progress[username]?.nil?
          info.progress[username] = {e.title => page}
        else
          info.progress[username][e.title] = page
        end
      end
      info.save
    end
  end
end

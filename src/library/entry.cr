require "image_size"

class Entry
  getter zip_path : String, book : Title, title : String,
    size : String, pages : Int32, id : String, encoded_path : String,
    encoded_title : String, mtime : Time, err_msg : String?

  def initialize(@zip_path, @book)
    storage = Storage.default
    @encoded_path = URI.encode @zip_path
    @title = File.basename @zip_path, File.extname @zip_path
    @encoded_title = URI.encode @title
    @size = (File.size @zip_path).humanize_bytes
    id = storage.get_entry_id @zip_path, File.signature(@zip_path)
    if id.nil?
      id = random_str
      storage.insert_entry_id({
        path:      @zip_path,
        id:        id,
        signature: File.signature(@zip_path).to_s,
      })
    end
    @id = id
    @mtime = File.info(@zip_path).modification_time

    unless File.readable? @zip_path
      @err_msg = "File #{@zip_path} is not readable."
      Logger.warn "#{@err_msg} Please make sure the " \
                  "file permission is configured correctly."
      return
    end

    archive_exception = validate_archive @zip_path
    unless archive_exception.nil?
      @err_msg = "Archive error: #{archive_exception}"
      Logger.warn "Unable to extract archive #{@zip_path}. " \
                  "Ignoring it. #{@err_msg}"
      return
    end

    file = ArchiveFile.new @zip_path
    @pages = file.entries.count do |e|
      SUPPORTED_IMG_TYPES.includes? \
        MIME.from_filename? e.filename
    end
    file.close
  end

  def to_json(json : JSON::Builder)
    json.object do
      {% for str in ["zip_path", "title", "size", "id"] %}
        json.field {{str}}, @{{str.id}}
      {% end %}
      json.field "title_id", @book.id
      json.field "display_name", @book.display_name @title
      json.field "cover_url", cover_url
      json.field "pages" { json.number @pages }
      json.field "mtime" { json.number @mtime.to_unix }
    end
  end

  def display_name
    @book.display_name @title
  end

  def encoded_display_name
    URI.encode display_name
  end

  def cover_url
    return "#{Config.current.base_url}img/icon.png" if @err_msg
    url = "#{Config.current.base_url}api/cover/#{@book.id}/#{@id}"
    TitleInfo.new @book.dir do |info|
      info_url = info.entry_cover_url[@title]?
      unless info_url.nil? || info_url.empty?
        url = File.join Config.current.base_url, info_url
      end
    end
    url
  end

  private def sorted_archive_entries
    ArchiveFile.open @zip_path do |file|
      entries = file.entries
        .select { |e|
          SUPPORTED_IMG_TYPES.includes? \
            MIME.from_filename? e.filename
        }
        .sort! { |a, b|
          compare_numerically a.filename, b.filename
        }
      yield file, entries
    end
  end

  def read_page(page_num)
    raise "Unreadble archive. #{@err_msg}" if @err_msg
    img = nil
    sorted_archive_entries do |file, entries|
      page = entries[page_num - 1]
      data = file.read_entry page
      if data
        img = Image.new data, MIME.from_filename(page.filename), page.filename,
          data.size
      end
    end
    img
  end

  def page_dimensions
    sizes = [] of Hash(String, Int32)
    sorted_archive_entries do |file, entries|
      entries.each_with_index do |e, i|
        begin
          data = file.read_entry(e).not_nil!
          size = ImageSize.get data
          sizes << {
            "width"  => size.width,
            "height" => size.height,
          }
        rescue e
          Logger.warn "Failed to read page #{i} of entry #{zip_path}. #{e}"
          sizes << {"width" => 1000_i32, "height" => 1000_i32}
        end
      end
    end
    sizes
  end

  def next_entry(username)
    entries = @book.sorted_entries username
    idx = entries.index self
    return nil if idx.nil? || idx == entries.size - 1
    entries[idx + 1]
  end

  def previous_entry(username)
    entries = @book.sorted_entries username
    idx = entries.index self
    return nil if idx.nil? || idx == 0
    entries[idx - 1]
  end

  def date_added
    date_added = nil
    TitleInfo.new @book.dir do |info|
      info_da = info.date_added[@title]?
      if info_da.nil?
        date_added = info.date_added[@title] = ctime @zip_path
        info.save
      else
        date_added = info_da
      end
    end
    date_added.not_nil! # is it ok to set not_nil! here?
  end

  # For backward backward compatibility with v0.1.0, we save entry titles
  #   instead of IDs in info.json
  def save_progress(username, page)
    TitleInfo.new @book.dir do |info|
      if info.progress[username]?.nil?
        info.progress[username] = {@title => page}
      else
        info.progress[username][@title] = page
      end
      # save last_read timestamp
      if info.last_read[username]?.nil?
        info.last_read[username] = {@title => Time.utc}
      else
        info.last_read[username][@title] = Time.utc
      end
      info.save
    end
  end

  def load_progress(username)
    progress = 0
    TitleInfo.new @book.dir do |info|
      unless info.progress[username]?.nil? ||
             info.progress[username][@title]?.nil?
        progress = info.progress[username][@title]
      end
    end
    [progress, @pages].min
  end

  def load_percentage(username)
    page = load_progress username
    page / @pages
  end

  def load_last_read(username)
    last_read = nil
    TitleInfo.new @book.dir do |info|
      unless info.last_read[username]?.nil? ||
             info.last_read[username][@title]?.nil?
        last_read = info.last_read[username][@title]
      end
    end
    last_read
  end

  def finished?(username)
    load_progress(username) == @pages
  end

  def started?(username)
    load_progress(username) > 0
  end

  def generate_thumbnail : Image?
    return if @err_msg

    img = read_page(1).not_nil!
    begin
      size = ImageSize.get img.data
      if size.height > size.width
        thumbnail = ImageSize.resize img.data, width: 200
      else
        thumbnail = ImageSize.resize img.data, height: 300
      end
      img.data = thumbnail
      img.size = thumbnail.size
      unless img.mime == "image/webp"
        # image_size.cr resizes non-webp images to jpg
        img.mime = "image/jpeg"
      end
      Storage.default.save_thumbnail @id, img
    rescue e
      Logger.warn "Failed to generate thumbnail for file #{@zip_path}. #{e}"
    end

    img
  end

  def get_thumbnail : Image?
    Storage.default.get_thumbnail @id
  end
end

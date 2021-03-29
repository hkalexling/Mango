IMGS_PER_PAGE            = 5
ENTRIES_IN_HOME_SECTIONS = 8
UPLOAD_URL_PREFIX        = "/uploads"
STATIC_DIRS              = %w(/css /js /img /webfonts /favicon.ico /robots.txt)
SUPPORTED_FILE_EXTNAMES  = [".zip", ".cbz", ".rar", ".cbr"]

def random_str
  UUID.random.to_s.gsub "-", ""
end

# Works in all Unix systems. Follows https://github.com/crystal-lang/crystal/
#   blob/master/src/crystal/system/unix/file_info.cr#L42-L48
def ctime(file_path : String) : Time
  res = LibC.stat(file_path, out stat)
  raise "Unable to get ctime of file #{file_path}" if res != 0

  {% if flag?(:darwin) %}
    Time.new stat.st_ctimespec, Time::Location::UTC
  {% else %}
    Time.new stat.st_ctim, Time::Location::UTC
  {% end %}
end

def register_mime_types
  {
    # Comic Archives
    ".zip" => "application/zip",
    ".rar" => "application/x-rar-compressed",
    ".cbz" => "application/vnd.comicbook+zip",
    ".cbr" => "application/vnd.comicbook-rar",

    # Favicon
    ".ico" => "image/x-icon",

    # FontAwesome fonts
    ".woff"  => "font/woff",
    ".woff2" => "font/woff2",
  }.each do |k, v|
    MIME.register k, v
  end
end

def is_supported_file(path)
  SUPPORTED_FILE_EXTNAMES.includes? File.extname(path).downcase
end

struct Int
  def or(other : Int)
    if self == 0
      other
    else
      self
    end
  end
end

struct Nil
  def or(other : Int)
    other
  end
end

macro use_default
  def self.default : self
    unless @@default
      @@default = new
    end
    @@default.not_nil!
  end
end

class String
  def alphanumeric_underscore?
    self.chars.all? { |c| c.alphanumeric? || c == '_' }
  end
end

def env_is_true?(key : String) : Bool
  val = ENV[key.upcase]? || ENV[key.downcase]?
  return false unless val
  val.downcase.in? "1", "true"
end

def sort_titles(titles : Array(Title), opt : SortOptions, username : String)
  ary = titles

  case opt.method
  when .time_modified?
    ary.sort! { |a, b| (a.mtime <=> b.mtime).or \
      compare_numerically a.title, b.title }
  when .progress?
    ary.sort! do |a, b|
      (a.load_percentage(username) <=> b.load_percentage(username)).or \
        compare_numerically a.title, b.title
    end
  else
    unless opt.method.auto?
      Logger.warn "Unknown sorting method #{opt.not_nil!.method}. Using " \
                  "Auto instead"
    end
    ary.sort! { |a, b| compare_numerically a.title, b.title }
  end

  ary.reverse! unless opt.not_nil!.ascend

  ary
end

class String
  # Returns the similarity (in [0, 1]) of two paths.
  # For the two paths, separate them into arrays of components, count the
  #   number of matching components backwards, and divide the count by the
  #   number of components of the shorter path.
  def components_similarity(other : String) : Float64
    s, l = [self, other]
      .map { |str| Path.new(str).parts }
      .sort_by! &.size

    match = s.reverse.zip(l.reverse).count { |a, b| a == b }
    match / s.size
  end
end

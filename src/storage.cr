require "sqlite3"
require "crypto/bcrypt"
require "uuid"
require "base64"
require "./util/*"
require "mg"
require "../migration/*"
require "./subscription"

def hash_password(pw)
  Crypto::Bcrypt::Password.create(pw).to_s
end

def verify_password(hash, pw)
  (Crypto::Bcrypt::Password.new hash).verify pw
end

SUB_ATTR = %w(manga_id language group_id min_volume max_volume min_chapter
  max_chapter username)

class Storage
  @@insert_entry_ids = [] of IDTuple
  @@insert_title_ids = [] of IDTuple

  @path : String
  @db : DB::Database?

  alias IDTuple = NamedTuple(
    path: String,
    id: String,
    signature: String?)

  use_default

  def initialize(db_path : String? = nil, init_user = true, *,
                 @auto_close = true)
    @path = db_path || Config.current.db_path
    dir = File.dirname @path
    unless Dir.exists? dir
      Logger.info "The DB directory #{dir} does not exist. " \
                  "Attempting to create it"
      Dir.mkdir_p dir
    end
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        begin
          MG::Migration.new(db, log: Logger.default.raw_log).migrate
        rescue e
          Logger.fatal "DB migration failed. #{e}"
          raise e
        end

        user_count = db.query_one "select count(*) from users", as: Int32
        init_admin if init_user && user_count == 0
      end
      unless @auto_close
        @db = DB.open "sqlite3://#{@path}"
      end
    end
  end

  macro init_admin
    random_pw = random_str
    hash = hash_password random_pw
    db.exec "insert into users values (?, ?, ?, ?)",
      "admin", hash, nil, 1
    Logger.log "Initial user created. You can log in with " \
               "#{{"username" => "admin", "password" => random_pw}}"
  end

  private def get_db(&block : DB::Database ->)
    if @db.nil?
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "PRAGMA foreign_keys = 1"
        yield db
      end
    else
      @db.not_nil!.exec "PRAGMA foreign_keys = 1"
      yield @db.not_nil!
    end
  end

  def username_exists(username)
    exists = false
    MainFiber.run do
      get_db do |db|
        exists = db.query_one("select count(*) from users where " \
                              "username = (?)", username, as: Int32) > 0
      end
    end
    exists
  end

  def username_is_admin(username)
    is_admin = false
    MainFiber.run do
      get_db do |db|
        is_admin = db.query_one("select admin from users where " \
                                "username = (?)", username, as: Int32) > 0
      end
    end
    is_admin
  end

  def verify_user(username, password)
    out_token = nil
    MainFiber.run do
      get_db do |db|
        begin
          hash, token = db.query_one "select password, token from " \
                                     "users where username = (?)",
            username, as: {String, String?}
          unless verify_password hash, password
            Logger.debug "Password does not match the hash"
            next
          end
          Logger.debug "User #{username} verified"
          if token
            out_token = token
            next
          end
          token = random_str
          Logger.debug "Updating token for #{username}"
          db.exec "update users set token = (?) where username = (?)",
            token, username
          out_token = token
        rescue e
          Logger.error "Error when verifying user #{username}: #{e}"
        end
      end
    end
    out_token
  end

  def verify_token(token)
    username = nil
    MainFiber.run do
      get_db do |db|
        begin
          username = db.query_one "select username from users where " \
                                  "token = (?)", token, as: String
        rescue e
          Logger.debug "Unable to verify token"
        end
      end
    end
    username
  end

  def verify_admin(token)
    is_admin = false
    MainFiber.run do
      get_db do |db|
        begin
          is_admin = db.query_one "select admin from users where " \
                                  "token = (?)", token, as: Bool
        rescue e
          Logger.debug "Unable to verify user as admin"
        end
      end
    end
    is_admin
  end

  def list_users
    results = Array(Tuple(String, Bool)).new
    MainFiber.run do
      get_db do |db|
        db.query "select username, admin from users" do |rs|
          rs.each do
            results << {rs.read(String), rs.read(Bool)}
          end
        end
      end
    end
    results
  end

  def new_user(username, password, admin)
    validate_username username
    validate_password password
    admin = (admin ? 1 : 0)
    MainFiber.run do
      get_db do |db|
        hash = hash_password password
        db.exec "insert into users values (?, ?, ?, ?)",
          username, hash, nil, admin
      end
    end
  end

  def update_user(original_username, username, password, admin)
    admin = (admin ? 1 : 0)
    validate_username username
    validate_password password unless password.empty?
    MainFiber.run do
      get_db do |db|
        if password.empty?
          db.exec "update users set username = (?), admin = (?) " \
                  "where username = (?)",
            username, admin, original_username
        else
          hash = hash_password password
          db.exec "update users set username = (?), admin = (?)," \
                  "password = (?) where username = (?)",
            username, admin, hash, original_username
        end
      end
    end
  end

  def delete_user(username)
    MainFiber.run do
      get_db do |db|
        db.exec "delete from users where username = (?)", username
      end
    end
  end

  def logout(token)
    MainFiber.run do
      get_db do |db|
        begin
          db.exec "update users set token = (?) where token = (?)", nil, token
        rescue
        end
      end
    end
  end

  def get_title_id(path, signature)
    id = nil
    path = Path.new(path).relative_to(Config.current.library_path).to_s
    MainFiber.run do
      get_db do |db|
        # First attempt to find the matching title in DB using BOTH path
        #   and signature
        id = db.query_one? "select id from titles where path = (?) and " \
                           "signature = (?) and unavailable = 0",
          path, signature.to_s, as: String

        should_update = id.nil?
        # If it fails, try to match using the path only. This could happen
        #   for example when a new entry is added to the title
        id ||= db.query_one? "select id from titles where path = (?)", path,
          as: String

        # If it still fails, we will have to rely on the signature values.
        #   This could happen when the user moved or renamed the title, or
        #   a title containing the title
        unless id
          # If there are multiple rows with the same signature (this could
          #   happen simply by bad luck, or when the user copied a title),
          #   pick the row that has the most similar path to the give path
          rows = [] of Tuple(String, String)
          db.query "select id, path from titles where signature = (?)",
            signature.to_s do |rs|
            rs.each do
              rows << {rs.read(String), rs.read(String)}
            end
          end
          row = rows.max_by?(&.[1].components_similarity(path))
          id = row[0] if row
        end

        # At this point, `id` would still be nil if there's no row matching
        #   either the path or the signature

        # If we did identify a matching title, save the path and signature
        #   values back to the DB
        if id && should_update
          db.exec "update titles set path = (?), signature = (?), " \
                  "unavailable = 0 where id = (?)", path, signature.to_s, id
        end
      end
    end
    id
  end

  # See the comments in `#get_title_id` to see how this method works.
  def get_entry_id(path, signature)
    id = nil
    path = Path.new(path).relative_to(Config.current.library_path).to_s
    MainFiber.run do
      get_db do |db|
        id = db.query_one? "select id from ids where path = (?) and " \
                           "signature = (?) and unavailable = 0",
          path, signature.to_s, as: String

        should_update = id.nil?
        id ||= db.query_one? "select id from ids where path = (?)", path,
          as: String

        unless id
          rows = [] of Tuple(String, String)
          db.query "select id, path from ids where signature = (?)",
            signature.to_s do |rs|
            rs.each do
              rows << {rs.read(String), rs.read(String)}
            end
          end
          row = rows.max_by?(&.[1].components_similarity(path))
          id = row[0] if row
        end

        if id && should_update
          db.exec "update ids set path = (?), signature = (?), " \
                  "unavailable = 0 where id = (?)", path, signature.to_s, id
        end
      end
    end
    id
  end

  def insert_entry_id(tp)
    @@insert_entry_ids << tp
  end

  def insert_title_id(tp)
    @@insert_title_ids << tp
  end

  def bulk_insert_ids
    MainFiber.run do
      get_db do |db|
        db.transaction do |tran|
          conn = tran.connection
          @@insert_title_ids.each do |tp|
            path = Path.new(tp[:path])
              .relative_to(Config.current.library_path).to_s
            conn.exec "insert into titles (id, path, signature, " \
                      "unavailable) values (?, ?, ?, 0)",
              tp[:id], path, tp[:signature].to_s
          end
          @@insert_entry_ids.each do |tp|
            path = Path.new(tp[:path])
              .relative_to(Config.current.library_path).to_s
            conn.exec "insert into ids (id, path, signature, " \
                      "unavailable) values (?, ?, ?, 0)",
              tp[:id], path, tp[:signature].to_s
          end
        end
      end
      @@insert_entry_ids.clear
      @@insert_title_ids.clear
    end
  end

  def save_thumbnail(id : String, img : Image)
    MainFiber.run do
      get_db do |db|
        db.exec "insert into thumbnails values (?, ?, ?, ?, ?)", id, img.data,
          img.filename, img.mime, img.size
      end
    end
  end

  def get_thumbnail(id : String) : Image?
    img = nil
    MainFiber.run do
      get_db do |db|
        db.query_one? "select * from thumbnails where id = (?)", id do |res|
          img = Image.from_db res
        end
      end
    end
    img
  end

  def get_title_tags(id : String) : Array(String)
    tags = [] of String
    MainFiber.run do
      get_db do |db|
        db.query "select tag from tags where id = (?) order by tag", id do |rs|
          rs.each do
            tags << rs.read String
          end
        end
      end
    end
    tags
  end

  def get_tag_titles(tag : String) : Array(String)
    tids = [] of String
    MainFiber.run do
      get_db do |db|
        db.query "select id from tags where tag = (?)", tag do |rs|
          rs.each do
            tids << rs.read String
          end
        end
      end
    end
    tids
  end

  def list_tags : Array(String)
    tags = [] of String
    MainFiber.run do
      get_db do |db|
        db.query "select distinct tag from tags natural join titles " \
                 "where unavailable = 0" do |rs|
          rs.each do
            tags << rs.read String
          end
        end
      end
    end
    tags
  end

  def add_tag(id : String, tag : String)
    err = nil
    MainFiber.run do
      begin
        get_db do |db|
          db.exec "insert into tags values (?, ?)", id, tag
        end
      rescue e
        err = e
      end
    end
    raise err.not_nil! if err
  end

  def delete_tag(id : String, tag : String)
    MainFiber.run do
      get_db do |db|
        db.exec "delete from tags where id = (?) and tag = (?)", id, tag
      end
    end
  end

  def mark_unavailable
    MainFiber.run do
      get_db do |db|
        # Detect dangling entry IDs
        trash_ids = [] of String
        db.query "select path, id from ids where unavailable = 0" do |rs|
          rs.each do
            path = rs.read String
            fullpath = Path.new(path).expand(Config.current.library_path).to_s
            trash_ids << rs.read String unless File.exists? fullpath
          end
        end

        unless trash_ids.empty?
          Logger.debug "Marking #{trash_ids.size} entries as unavailable"
        end
        db.exec "update ids set unavailable = 1 where id in " \
                "(#{trash_ids.join "," { |i| "'#{i}'" }})"

        # Detect dangling title IDs
        trash_titles = [] of String
        db.query "select path, id from titles where unavailable  = 0" do |rs|
          rs.each do
            path = rs.read String
            fullpath = Path.new(path).expand(Config.current.library_path).to_s
            trash_titles << rs.read String unless Dir.exists? fullpath
          end
        end

        unless trash_titles.empty?
          Logger.debug "Marking #{trash_titles.size} titles as unavailable"
        end
        db.exec "update titles set unavailable = 1 where id in " \
                "(#{trash_titles.join "," { |i| "'#{i}'" }})"
      end
    end
  end

  private def get_missing(tablename)
    ary = [] of IDTuple
    MainFiber.run do
      get_db do |db|
        db.query "select id, path, signature from #{tablename} " \
                 "where unavailable = 1" do |rs|
          rs.each do
            ary << {
              id:        rs.read(String),
              path:      rs.read(String),
              signature: rs.read(String?),
            }
          end
        end
      end
    end
    ary
  end

  private def delete_missing(tablename, id : String? = nil)
    MainFiber.run do
      get_db do |db|
        if id
          db.exec "delete from #{tablename} where id = (?) " \
                  "and unavailable = 1", id
        else
          db.exec "delete from #{tablename} where unavailable = 1"
        end
      end
    end
  end

  def missing_entries
    get_missing "ids"
  end

  def missing_titles
    get_missing "titles"
  end

  def delete_missing_entry(id = nil)
    delete_missing "ids", id
  end

  def delete_missing_title(id = nil)
    delete_missing "titles", id
  end

  def save_md_token(username : String, token : String, expire : Time)
    MainFiber.run do
      get_db do |db|
        count = db.query_one "select count(*) from md_account where " \
                             "username = (?)", username, as: Int64
        if count == 0
          db.exec "insert into md_account values (?, ?, ?)", username, token,
            expire.to_unix
        else
          db.exec "update md_account set token = (?), expire = (?) " \
                  "where username = (?)", token, expire.to_unix, username
        end
      end
    end
  end

  def get_md_token(username) : Tuple(String?, Time?)
    token = nil
    expires = nil
    MainFiber.run do
      get_db do |db|
        db.query_one? "select token, expire from md_account where " \
                      "username = (?)", username do |res|
          token = res.read String
          expires = Time.unix res.read Int64
        end
      end
    end
    {token, expires}
  end

  def save_subscription(sub : Subscription)
    MainFiber.run do
      get_db do |db|
        {% begin %}
          db.exec "insert into subscription (#{SUB_ATTR.join ","}, " \
            "last_checked, created_at) values " \
            "(#{Array.new(SUB_ATTR.size + 2, "?").join ","})",
          {% for type in SUB_ATTR %}
            sub.{{type.id}},
          {% end %}
          sub.last_checked.to_unix, sub.created_at.to_unix
        {% end %}
      end
    end
  end

  def subscriptions : Array(Subscription)
    subs = [] of Subscription
    MainFiber.run do
      get_db do |db|
        db.query "select * from subscription" do |rs|
          subs += Subscription.from_rs rs
        end
      end
    end
    subs
  end

  def delete_subscription(id : Int64, username : String)
    MainFiber.run do
      get_db do |db|
        db.exec "delete from subscription where id = (?) and username = (?)",
          id, username
      end
    end
  end

  def get_subscription(id : Int64, username : String) : Subscription?
    sub = nil
    MainFiber.run do
      get_db do |db|
        db.query "select * from subscription where id = (?) and " \
                 "username = (?) limit 1", id, username do |rs|
          sub = Subscription.from_rs(rs).first?
        end
      end
    end
    sub
  end

  def update_subscription_last_checked(id : Int64? = nil)
    MainFiber.run do
      get_db do |db|
        if id
          db.exec "update subscription set last_checked = (?) where id = (?)",
            Time.utc.to_unix, id
        else
          db.exec "update subscription set last_checked = (?)",
            Time.utc.to_unix
        end
      end
    end
  end

  def close
    MainFiber.run do
      unless @db.nil?
        @db.not_nil!.close
      end
    end
  end

  def to_json(json : JSON::Builder)
    json.string self
  end
end

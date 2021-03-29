require "sqlite3"
require "./util/*"

class Queue
  abstract class Downloader
    property stopped = false
    @library_path : String = Config.current.library_path
    @downloading = false

    def initialize
      @queue = Queue.default
      @queue << self

      spawn do
        loop do
          sleep 1.second
          next if @stopped || @downloading
          begin
            job = pop
            next if job.nil?
            download job
          rescue e
            Logger.error e
            @downloading = false
          end
        end
      end
    end

    abstract def pop : Job?
    private abstract def download(job : Job)
  end

  enum JobStatus
    Pending      # 0
    Downloading  # 1
    Error        # 2
    Completed    # 3
    MissingPages # 4
  end

  struct Job
    property id : String
    property manga_id : String
    property title : String
    property manga_title : String
    property status : JobStatus
    property status_message : String = ""
    property pages : Int32 = 0
    property success_count : Int32 = 0
    property fail_count : Int32 = 0
    property time : Time
    property plugin_id : String?
    property plugin_chapter_id : String?

    def parse_query_result(res : DB::ResultSet)
      @id = res.read String
      @manga_id = res.read String
      @title = res.read String
      @manga_title = res.read String
      status = res.read Int32
      @status_message = res.read String
      @pages = res.read Int32
      @success_count = res.read Int32
      @fail_count = res.read Int32
      time = res.read Int64
      @status = JobStatus.new status
      @time = Time.unix_ms time

      ary = @id.split("-")
      if ary.size == 2
        @plugin_id = ary[0]
        @plugin_chapter_id = ary[1]
      end
    end

    # Raises if the result set does not contain the correct set of columns
    def self.from_query_result(res : DB::ResultSet)
      job = Job.allocate
      job.parse_query_result res
      job
    end

    def initialize(@id, @manga_id, @title, @manga_title, @status, @time,
                   @plugin_id = nil)
    end

    def to_json(json)
      json.object do
        {% for name in ["id", "manga_id", "title", "manga_title",
                        "status_message"] %}
          json.field {{name}}, @{{name.id}}
        {% end %}
        {% for name in ["pages", "success_count", "fail_count"] %}
          json.field {{name}} do
            json.number @{{name.id}}
          end
        {% end %}
        json.field "status", @status.to_s
        json.field "time" do
          json.number @time.to_unix_ms
        end
        json.field "plugin_id", @plugin_id if @plugin_id
      end
    end
  end

  getter path : String
  @downloaders = [] of Downloader
  @paused = false

  use_default

  def initialize(db_path : String? = nil)
    @path = db_path || Config.current.mangadex["download_queue_db_path"].to_s
    dir = File.dirname @path
    unless Dir.exists? dir
      Logger.info "The queue DB directory #{dir} does not exist. " \
                  "Attepmting to create it"
      Dir.mkdir_p dir
    end
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        begin
          db.exec "create table if not exists queue " \
                  "(id text, manga_id text, title text, manga_title " \
                  "text, status integer, status_message text, " \
                  "pages integer, success_count integer, " \
                  "fail_count integer, time integer)"
          db.exec "create unique index if not exists id_idx " \
                  "on queue (id)"
          db.exec "create index if not exists manga_id_idx " \
                  "on queue (manga_id)"
          db.exec "create index if not exists status_idx " \
                  "on queue (status)"
        rescue e
          Logger.error "Error when checking tables in DB: #{e}"
          raise e
        end
      end
    end
  end

  # Push an array of jobs into the queue, and return the number of jobs
  #   inserted. Any job already exists in the queue will be ignored.
  def push(jobs : Array(Job))
    start_count = self.count
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        jobs.each do |job|
          db.exec "insert or ignore into queue values " \
                  "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            job.id, job.manga_id, job.title, job.manga_title,
            job.status.to_i, job.status_message, job.pages,
            job.success_count, job.fail_count, job.time.to_unix_ms
        end
      end
    end
    self.count - start_count
  end

  def reset(id : String)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set status = 0, status_message = '', " \
                "pages = 0, success_count = 0, fail_count = 0 " \
                "where id = (?)", id
      end
    end
  end

  def reset(job : Job)
    self.reset job.id
  end

  # Reset all failed tasks (missing pages and error)
  def reset
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set status = 0, status_message = '', " \
                "pages = 0, success_count = 0, fail_count = 0 " \
                "where status = 2 or status = 4"
      end
    end
  end

  def delete(id : String)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "delete from queue where id = (?)", id
      end
    end
  end

  def delete(job : Job)
    self.delete job.id
  end

  def exists?(id : String)
    res = false
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        res = db.query_one "select count(*) from queue where id = (?)", id,
          as: Bool
      end
    end
    res
  end

  def exists?(job : Job)
    self.exists? job.id
  end

  def delete_status(status : JobStatus)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "delete from queue where status = (?)", status.to_i
      end
    end
  end

  def count_status(status : JobStatus)
    num = 0
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        num = db.query_one "select count(*) from queue where " \
                           "status = (?)", status.to_i, as: Int32
      end
    end
    num
  end

  def count
    num = 0
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        num = db.query_one "select count(*) from queue", as: Int32
      end
    end
    num
  end

  def set_status(status : JobStatus, job : Job)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set status = (?) where id = (?)",
          status.to_i, job.id
      end
    end
  end

  def get_all
    jobs = [] of Job
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        jobs = db.query_all "select * from queue order by time" do |rs|
          Job.from_query_result rs
        end
      end
    end
    jobs
  end

  def add_success(job : Job)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set success_count = success_count + 1 " \
                "where id = (?)", job.id
      end
    end
  end

  def add_fail(job : Job)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set fail_count = fail_count + 1 " \
                "where id = (?)", job.id
      end
    end
  end

  def set_pages(pages : Int32, job : Job)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set pages = (?), success_count = 0, " \
                "fail_count = 0 where id = (?)", pages, job.id
      end
    end
  end

  def add_message(msg : String, job : Job)
    MainFiber.run do
      DB.open "sqlite3://#{@path}" do |db|
        db.exec "update queue set status_message = " \
                "status_message || (?) || (?) where id = (?)",
          "\n", msg, job.id
      end
    end
  end

  def <<(downloader : Downloader)
    @downloaders << downloader
  end

  def pause
    @downloaders.each &.stopped=(true)
    @paused = true
  end

  def resume
    @downloaders.each &.stopped=(false)
    @paused = false
  end

  def paused?
    @paused
  end
end

require "mangadex"
require "compress/zip"
require "../rename"
require "./ext"

module MangaDex
  class PageJob
    property success = false
    property url : String
    property filename : String
    property writer : Compress::Zip::Writer
    property tries_remaning : Int32

    def initialize(@url, @filename, @writer, @tries_remaning)
    end
  end

  class Downloader < Queue::Downloader
    @wait_seconds : Int32 = Config.current.mangadex["download_wait_seconds"]
      .to_i32
    @retries : Int32 = Config.current.mangadex["download_retries"].to_i32

    use_default

    def initialize
      @client = Client.from_config
      super
    end

    def pop : Queue::Job?
      job = nil
      MainFiber.run do
        DB.open "sqlite3://#{@queue.path}" do |db|
          begin
            db.query_one "select * from queue where id not like '%-%' " \
                         "and (status = 0 or status = 1) " \
                         "order by time limit 1" do |res|
              job = Queue::Job.from_query_result res
            end
          rescue
          end
        end
      end
      job
    end

    private def download(job : Queue::Job)
      @downloading = true
      @queue.set_status Queue::JobStatus::Downloading, job
      begin
        chapter = @client.chapter job.id
        # We must put the `.pages` call in a rescue block to handle external
        #   chapters.
        pages = chapter.pages
      rescue e
        Logger.error e
        @queue.set_status Queue::JobStatus::Error, job
        unless e.message.nil?
          @queue.add_message e.message.not_nil!, job
        end
        @downloading = false
        return
      end
      @queue.set_pages pages.size, job
      lib_dir = @library_path
      rename_rule = Rename::Rule.new \
        Config.current.mangadex["manga_rename_rule"].to_s
      manga_dir = File.join lib_dir, chapter.manga.rename rename_rule
      unless File.exists? manga_dir
        Dir.mkdir_p manga_dir
      end
      zip_path = File.join manga_dir, "#{job.title}.cbz.part"

      # Find the number of digits needed to store the number of pages
      len = Math.log10(pages.size).to_i + 1

      writer = Compress::Zip::Writer.new zip_path
      # Create a buffered channel. It works as an FIFO queue
      channel = Channel(PageJob).new pages.size
      spawn do
        pages.each_with_index do |url, i|
          fn = Path.new(URI.parse(url).path).basename
          ext = File.extname fn
          fn = "#{i.to_s.rjust len, '0'}#{ext}"
          page_job = PageJob.new url, fn, writer, @retries
          Logger.debug "Downloading #{url}"
          loop do
            sleep @wait_seconds.seconds
            download_page page_job
            break if page_job.success ||
                     page_job.tries_remaning <= 0
            page_job.tries_remaning -= 1
            Logger.warn "Failed to download page #{url}. " \
                        "Retrying... Remaining retries: " \
                        "#{page_job.tries_remaning}"
          end

          channel.send page_job
          break unless @queue.exists? job
        end
      end

      spawn do
        page_jobs = [] of PageJob
        pages.size.times do
          page_job = channel.receive

          break unless @queue.exists? job

          Logger.debug "[#{page_job.success ? "success" : "failed"}] " \
                       "#{page_job.url}"
          page_jobs << page_job
          if page_job.success
            @queue.add_success job
          else
            @queue.add_fail job
            msg = "Failed to download page #{page_job.url}"
            @queue.add_message msg, job
            Logger.error msg
          end
        end

        unless @queue.exists? job
          Logger.debug "Download cancelled"
          @downloading = false
          next
        end

        fail_count = page_jobs.count { |j| !j.success }
        Logger.debug "Download completed. " \
                     "#{fail_count}/#{page_jobs.size} failed"
        writer.close
        filename = File.join File.dirname(zip_path), File.basename(zip_path,
          ".part")
        File.rename zip_path, filename
        Logger.debug "cbz File created at #{filename}"

        zip_exception = validate_archive filename
        if !zip_exception.nil?
          @queue.add_message "The downloaded archive is corrupted. " \
                             "Error: #{zip_exception}", job
          @queue.set_status Queue::JobStatus::Error, job
        elsif fail_count > 0
          @queue.set_status Queue::JobStatus::MissingPages, job
        else
          @queue.set_status Queue::JobStatus::Completed, job
        end
        @downloading = false
      end
    end

    private def download_page(job : PageJob)
      Logger.debug "downloading #{job.url}"
      headers = HTTP::Headers{
        "User-agent" => "Mangadex.cr",
      }
      begin
        HTTP::Client.get job.url, headers do |res|
          unless res.success?
            raise "Failed to download page #{job.url}. " \
                  "[#{res.status_code}] #{res.status_message}"
          end
          job.writer.add job.filename, res.body_io
        end
        job.success = true
      rescue e
        Logger.error e
        job.success = false
      end
    end
  end
end

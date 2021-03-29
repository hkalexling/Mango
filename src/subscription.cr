require "db"
require "json"

struct Subscription
  include DB::Serializable
  include JSON::Serializable

  getter id : Int64 = 0
  getter username : String
  getter manga_id : Int64
  property language : String?
  property group_id : Int64?
  property min_volume : Int64?
  property max_volume : Int64?
  property min_chapter : Int64?
  property max_chapter : Int64?
  @[DB::Field(key: "last_checked")]
  @[JSON::Field(key: "last_checked")]
  @raw_last_checked : Int64
  @[DB::Field(key: "created_at")]
  @[JSON::Field(key: "created_at")]
  @raw_created_at : Int64

  def last_checked : Time
    Time.unix @raw_last_checked
  end

  def created_at : Time
    Time.unix @raw_created_at
  end

  def initialize(@manga_id, @username)
    @raw_created_at = Time.utc.to_unix
    @raw_last_checked = Time.utc.to_unix
  end

  private def in_range?(value : String, lowerbound : Int64?,
                        upperbound : Int64?) : Bool
    lb = lowerbound.try &.to_f64
    ub = upperbound.try &.to_f64

    return true if lb.nil? && ub.nil?

    v = value.to_f64?
    return false unless v

    if lb.nil?
      v <= ub.not_nil!
    elsif ub.nil?
      v >= lb.not_nil!
    else
      v >= lb.not_nil! && v <= ub.not_nil!
    end
  end

  def match?(chapter : MangaDex::Chapter) : Bool
    if chapter.manga_id != manga_id ||
       (language && chapter.language != language) ||
       (group_id && !chapter.groups.map(&.id).includes? group_id)
      return false
    end

    in_range?(chapter.volume, min_volume, max_volume) &&
      in_range?(chapter.chapter, min_chapter, max_chapter)
  end

  def check_for_updates : Int32
    Logger.debug "Checking updates for subscription with ID #{id}"
    jobs = [] of Queue::Job
    get_client(username).user.updates_after last_checked do |chapter|
      next unless match? chapter
      jobs << chapter.to_job
    end
    Storage.default.update_subscription_last_checked id
    count = Queue.default.push jobs
    Logger.debug "#{count}/#{jobs.size} of updates added to queue"
    count
  rescue e
    Logger.error "Error occurred when checking updates for " \
                 "subscription with ID #{id}. #{e}"
    0
  end
end

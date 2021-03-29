private macro properties_to_hash(names)
  {
    {% for name in names %}
      "{{name.id}}" => {{name.id}}.to_s,
    {% end %}
  }
end

# Monkey-patch the structures in the `mangadex` shard to suit our needs
module MangaDex
  struct Client
    @@group_cache = {} of String => Group

    def self.from_config : Client
      self.new base_url: Config.current.mangadex["base_url"].to_s,
        api_url: Config.current.mangadex["api_url"].to_s
    end
  end

  struct Manga
    def rename(rule : Rename::Rule)
      rule.render properties_to_hash %w(id title author artist)
    end

    def to_info_json
      hash = JSON.parse(to_json).as_h
      _chapters = chapters.map do |c|
        JSON.parse c.to_info_json
      end
      hash["chapters"] = JSON::Any.new _chapters
      hash.to_json
    end
  end

  struct Chapter
    def rename(rule : Rename::Rule)
      hash = properties_to_hash %w(id title volume chapter lang_code language)
      hash["groups"] = groups.join(",", &.name)
      rule.render hash
    end

    def full_title
      rule = Rename::Rule.new \
        Config.current.mangadex["chapter_rename_rule"].to_s
      rename rule
    end

    def to_info_json
      hash = JSON.parse(to_json).as_h
      hash["language"] = JSON::Any.new language
      _groups = {} of String => JSON::Any
      groups.each do |g|
        _groups[g.name] = JSON::Any.new g.id
      end
      hash["groups"] = JSON::Any.new _groups
      hash["full_title"] = JSON::Any.new full_title
      hash.to_json
    end

    # We don't need to rename the manga title here. It will be renamed in
    #   src/mangadex/downloader.cr
    def to_job : Queue::Job
      Queue::Job.new(
        id.to_s,
        manga_id.to_s,
        full_title,
        manga_title,
        Queue::JobStatus::Pending,
        Time.unix timestamp
      )
    end
  end

  struct User
    def updates_after(time : Time, &block : Chapter ->)
      page = 1
      stopped = false
      until stopped
        chapters = followed_updates(page: page).chapters
        return if chapters.empty?
        chapters.each do |c|
          if time > Time.unix c.timestamp
            stopped = true
            break
          end
          yield c
        end
        page += 1
        # Let's not DDOS MangaDex :)
        sleep 5.seconds
      end
    end
  end
end

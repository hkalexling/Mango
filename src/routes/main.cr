struct MainRouter
  def initialize
    get "/login" do |env|
      base_url = Config.current.base_url
      render "src/views/login.html.ecr"
    end

    get "/logout" do |env|
      begin
        env.session.delete_string "token"
      rescue e
        Logger.error "Error when attempting to log out: #{e}"
      ensure
        redirect env, "/login"
      end
    end

    post "/login" do |env|
      begin
        username = env.params.body["username"]
        password = env.params.body["password"]
        token = Storage.default.verify_user(username, password).not_nil!

        env.session.string "token", token

        callback = env.session.string? "callback"
        if callback
          env.session.delete_string "callback"
          redirect env, callback
        else
          redirect env, "/"
        end
      rescue
        redirect env, "/login"
      end
    end

    get "/library" do |env|
      begin
        username = get_username env

        sort_opt = SortOptions.from_info_json Library.default.dir, username
        get_sort_opt

        titles = Library.default.sorted_titles username, sort_opt
        percentage = titles.map &.load_percentage username

        layout "library"
      rescue e
        Logger.error e
        env.response.status_code = 500
      end
    end

    get "/book/:title" do |env|
      begin
        title = (Library.default.get_title env.params.url["title"]).not_nil!
        username = get_username env

        sort_opt = SortOptions.from_info_json title.dir, username
        get_sort_opt

        entries = title.sorted_entries username, sort_opt

        percentage = title.load_percentage_for_all_entries username, sort_opt
        title_percentage = title.titles.map &.load_percentage username
        layout "title"
      rescue e
        Logger.error e
        env.response.status_code = 500
      end
    end

    get "/download" do |env|
      mangadex_base_url = Config.current.mangadex["base_url"]
      layout "download"
    end

    get "/download/plugins" do |env|
      begin
        id = env.params.query["plugin"]?
        plugins = Plugin.list
        plugin = nil

        if id
          plugin = Plugin.new id
        elsif !plugins.empty?
          plugin = Plugin.new plugins[0][:id]
        end

        layout "plugin-download"
      rescue e
        Logger.error e
        env.response.status_code = 500
      end
    end

    get "/download/subscription" do |env|
      mangadex_base_url = Config.current.mangadex["base_url"]
      username = get_username env
      layout "subscription"
    end

    get "/" do |env|
      begin
        username = get_username env
        continue_reading = Library.default
          .get_continue_reading_entries username
        recently_added = Library.default.get_recently_added_entries username
        start_reading = Library.default.get_start_reading_titles username
        titles = Library.default.titles
        new_user = !titles.any? &.load_percentage(username).> 0
        empty_library = titles.size == 0
        layout "home"
      rescue e
        Logger.error e
        env.response.status_code = 500
      end
    end

    get "/tags/:tag" do |env|
      begin
        username = get_username env
        tag = env.params.url["tag"]

        sort_opt = SortOptions.new
        get_sort_opt

        title_ids = Storage.default.get_tag_titles tag

        raise "Tag #{tag} not found" if title_ids.empty?

        titles = title_ids.map { |id| Library.default.get_title id }
          .select Title

        titles = sort_titles titles, sort_opt, username
        percentage = titles.map &.load_percentage username

        layout "tag"
      rescue e
        Logger.error e
        env.response.status_code = 404
      end
    end

    get "/tags" do |env|
      tags = Storage.default.list_tags.map do |tag|
        {
          tag:         tag,
          encoded_tag: URI.encode_www_form(tag, space_to_plus: false),
          count:       Storage.default.get_tag_titles(tag).size,
        }
      end
      # Sort by :count reversly, and then sort by :tag
      tags.sort! do |a, b|
        (b[:count] <=> a[:count]).or(a[:tag] <=> b[:tag])
      end

      layout "tags"
    end

    get "/api" do |env|
      base_url = Config.current.base_url
      render "src/views/api.html.ecr"
    end
  end
end

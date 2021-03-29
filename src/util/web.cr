# Web related helper functions/macros

def is_admin?(env) : Bool
  is_admin = false
  if !Config.current.auth_proxy_header_name.empty? ||
     Config.current.disable_login
    is_admin = Storage.default.username_is_admin get_username env
  end

  # The token (if exists) takes precedence over other authentication methods.
  if token = env.session.string? "token"
    is_admin = Storage.default.verify_admin token
  end

  is_admin
end

macro layout(name)
  base_url = Config.current.base_url
  is_admin = is_admin? env
  begin
    page = {{name}}
    render "src/views/#{{{name}}}.html.ecr", "src/views/layout.html.ecr"
  rescue e
    message = e.to_s
    Logger.error message
    page = "Error"
    render "src/views/message.html.ecr", "src/views/layout.html.ecr"
  end
end

macro send_error_page(msg)
  message = {{msg}}
  base_url = Config.current.base_url
  is_admin = is_admin? env
  page = "Error"
  html = render "src/views/message.html.ecr", "src/views/layout.html.ecr"
  send_file env, html.to_slice, "text/html"
end

macro send_img(env, img)
  send_file {{env}}, {{img}}.data, {{img}}.mime
end

macro get_username(env)
  begin
    token = env.session.string "token"
    (Storage.default.verify_token token).not_nil!
  rescue e
    if Config.current.disable_login
      Config.current.default_username
    elsif (header = Config.current.auth_proxy_header_name) && !header.empty?
      env.request.headers[header]
    else
      raise e
    end
  end
end

def send_json(env, json)
  env.response.content_type = "application/json"
  env.response.print json
end

def send_attachment(env, path)
  send_file env, path, filename: File.basename(path), disposition: "attachment"
end

def redirect(env, path)
  base = Config.current.base_url
  env.redirect File.join base, path
end

def hash_to_query(hash)
  hash.join "&" { |k, v| "#{k}=#{v}" }
end

def request_path_startswith(env, ary)
  ary.any? { |prefix| env.request.path.starts_with? prefix }
end

def requesting_static_file(env)
  request_path_startswith env, STATIC_DIRS
end

macro render_xml(path)
  base_url = Config.current.base_url
  send_file env, ECR.render({{path}}).to_slice, "application/xml"
end

macro render_component(filename)
  render "src/views/components/#{{{filename}}}.html.ecr"
end

macro get_sort_opt
  sort_method = env.params.query["sort"]?

  if sort_method
    is_ascending = true

    ascend = env.params.query["ascend"]?
    if ascend && ascend.to_i? == 0
      is_ascending = false
    end

    sort_opt = SortOptions.new sort_method, is_ascending
  end
end

# Returns an authorized client
def get_client(username : String) : MangaDex::Client
  token, expires = Storage.default.get_md_token username

  unless expires && token
    raise "No token found for user #{username}"
  end

  client = MangaDex::Client.from_config
  client.token = token
  client.token_expires = expires

  client
end

def get_client(env) : MangaDex::Client
  get_client get_username env
end

module HTTP
  class Client
    private def self.exec(uri : URI, tls : TLSContext = nil)
      previous_def uri, tls do |client, path|
        if client.tls? && env_is_true? "DISABLE_SSL_VERIFICATION"
          Logger.debug "Disabling SSL verification"
          client.tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
        Logger.debug "Setting read timeout"
        client.read_timeout = Config.current.download_timeout_seconds.seconds
        Logger.debug "Requesting #{uri}"
        yield client, path
      end
    end
  end
end

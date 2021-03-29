require "./config"
require "./queue"
require "./server"
require "./main_fiber"
require "./mangadex/*"
require "./plugin/*"
require "option_parser"
require "clim"
require "tallboy"

MANGO_VERSION = "0.22.0"

# From http://www.network-science.de/ascii/
BANNER = %{

              _|      _|
              _|_|  _|_|    _|_|_|  _|_|_|      _|_|_|    _|_|
              _|  _|  _|  _|    _|  _|    _|  _|    _|  _|    _|
              _|      _|  _|    _|  _|    _|  _|    _|  _|    _|
              _|      _|    _|_|_|  _|    _|    _|_|_|    _|_|
                                                    _|
                                                _|_|


}

DESCRIPTION = "Mango - Manga Server and Web Reader. Version #{MANGO_VERSION}"

macro common_option
  option "-c PATH", "--config=PATH", type: String,
    desc: "Path to the config file"
end

macro throw(msg)
  puts "ERROR: #{{{msg}}}"
  puts
  puts "Please see the `--help`."
  exit 1
end

class CLI < Clim
  main do
    desc DESCRIPTION
    usage "mango [sub_command] [options]"
    help short: "-h"
    version "Version #{MANGO_VERSION}", short: "-v"
    common_option
    run do |opts|
      puts BANNER
      puts DESCRIPTION
      puts

      # empty ARGV so it won't be passed to Kemal
      ARGV.clear

      Config.load(opts.config).set_current

      # Initialize main components
      Storage.default
      Queue.default
      Library.default
      MangaDex::Downloader.default
      Plugin::Downloader.default

      spawn do
        begin
          Server.new.start
        rescue e
          Logger.fatal e
          Process.exit 1
        end
      end

      MainFiber.start_and_block
    end

    sub "admin" do
      desc "Run admin tools"
      usage "mango admin [tool]"
      help short: "-h"
      run do |opts|
        puts opts.help_string
      end
      sub "user" do
        desc "User management tool"
        usage "mango admin user [arguments] [options]"
        help short: "-h"
        argument "action", type: String,
          desc: "Action to perform. Can be add/delete/update/list"
        argument "username", type: String,
          desc: "Username to update or delete"
        option "-u USERNAME", "--username=USERNAME", type: String,
          desc: "Username"
        option "-p PASSWORD", "--password=PASSWORD", type: String,
          desc: "Password"
        option "-a", "--admin", desc: "Admin flag", type: Bool, default: false
        common_option
        run do |opts, args|
          Config.load(opts.config).set_current
          storage = Storage.new nil, false

          case args.action
          when "add"
            throw "Options `-u` and `-p` required." if opts.username.nil? ||
                                                       opts.password.nil?
            storage.new_user opts.username.not_nil!,
              opts.password.not_nil!, opts.admin
          when "delete"
            throw "Argument `username` required." if args.username.nil?
            storage.delete_user args.username
          when "update"
            throw "Argument `username` required." if args.username.nil?
            username = opts.username || args.username
            password = opts.password || ""
            storage.update_user args.username, username.not_nil!,
              password.not_nil!, opts.admin
          when "list"
            users = storage.list_users
            table = Tallboy.table do
              header ["username", "admin access"]
              users.each do |name, admin|
                row [name, admin]
              end
            end
            puts table
          when nil
            puts opts.help_string
          else
            throw "Unknown action \"#{args.action}\"."
          end
        end
      end
    end
  end
end

CLI.start(ARGV)

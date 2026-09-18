#!/usr/bin/env ruby

require "commander-tool"
require "json"
require "net/http"
require "uri"
require "fileutils"
require "socket"

module VpnTool
  BASE_URL = "https://vpn-data-cleaner-api--hb044082.replit.app"
  VERSION = "1.0.0"

  CONFIG_DIR = File.join(Dir.home, ".vpn-tool")
  PIN_FILE = File.join(CONFIG_DIR, "pin")
  SESSION_FILE = File.join(CONFIG_DIR, "session")
  DAEMON_PID_FILE = File.join(CONFIG_DIR, "daemon.pid")

  DAEMON_HOST = "127.0.0.1"
  DAEMON_PORT = 5900

  module_function

  def ensure_config
    FileUtils.mkdir_p(CONFIG_DIR)
    File.chmod(0o700, CONFIG_DIR)
  end

  def file_exists?(path)
    File.file?(path)
  end

  def read_file(path)
    return nil unless file_exists?(path)

    File.read(path).strip
  end

  def write_file(path, value)
    ensure_config

    File.write(path, value)
    File.chmod(0o600, path)

    true
  rescue StandardError => e
    warn "Error: #{e.message}"
    false
  end

  def remove_file(path)
    File.delete(path) if File.exist?(path)
  end

  def valid_pin?(pin)
    pin && pin.match?(/\A\d{4}\z/)
  end

  def prompt(message)
    print message
    $stdout.flush
    STDIN.gets&.chomp
  end

  # ----------------------------------------------------------
  # Authentication
  # ----------------------------------------------------------

  def require_login
    return true if file_exists?(SESSION_FILE)

    puts "Not logged in."
    puts "Run: vpn-tool auth login"

    false
  end

  def check_pin(message)
    unless file_exists?(PIN_FILE)
      puts "No PIN registered."
      puts "Run: vpn-tool auth register"
      return false
    end

    pin = prompt(message)
    saved_pin = read_file(PIN_FILE)

    unless pin == saved_pin
      puts "Incorrect PIN."
      return false
    end

    true
  end

  # ----------------------------------------------------------
  # Daemon
  # ----------------------------------------------------------

  def daemon_pid
    value = read_file(DAEMON_PID_FILE)

    return nil unless value&.match?(/\A\d+\z/)

    value.to_i
  end

  def daemon_running?
    pid = daemon_pid

    return false unless pid && pid > 0

    begin
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end
  end

  def daemon_connection
    TCPSocket.new(
      DAEMON_HOST,
      DAEMON_PORT
    )
  rescue StandardError
    nil
  end

  def require_daemon
    socket = daemon_connection

    if socket
      socket.close
      return true
    end

    puts "Cannot connect to daemon server."
    puts "Run: vpn-tool start --daemon"

    false
  end

  def start_daemon
    ensure_config

    if daemon_running?
      puts "Daemon already running (PID #{daemon_pid})."
      puts "TCP: tcp://#{DAEMON_HOST}:#{DAEMON_PORT}"
      return
    end

    remove_file(DAEMON_PID_FILE)

    pid = fork do
      Process.setsid

      begin
        server = TCPServer.new(
          DAEMON_HOST,
          DAEMON_PORT
        )

        write_file(
          DAEMON_PID_FILE,
          Process.pid.to_s
        )

        loop do
          client = server.accept

          begin
            request = client.gets&.chomp

            response =
              case request
              when "PING", "STATUS"
                {
                  status: "running",
                  service: "vpn-tool-daemon",
                  version: VERSION,
                  pid: Process.pid,
                  host: DAEMON_HOST,
                  port: DAEMON_PORT
                }
              else
                {
                  status: "ok",
                  service: "vpn-tool-daemon",
                  version: VERSION
                }
              end

            client.puts(
              JSON.generate(response)
            )
          rescue StandardError => e
            client.puts(
              JSON.generate(
                status: "error",
                message: e.message
              )
            )
          ensure
            client.close
          end
        end
      rescue StandardError => e
        warn "Daemon error: #{e.message}"
      ensure
        remove_file(DAEMON_PID_FILE)
      end
    end

    Process.detach(pid)

    sleep 0.2

    if daemon_running?
      puts "Daemon started."
      puts "TCP: tcp://#{DAEMON_HOST}:#{DAEMON_PORT}"
      puts "PID: #{daemon_pid}"
    else
      puts "Cannot start daemon."
    end
  rescue StandardError => e
    warn "Error starting daemon: #{e.message}"
  end

  def stop_daemon
    pid = daemon_pid

    unless pid && daemon_running?
      remove_file(DAEMON_PID_FILE)

      puts "Daemon not running."
      puts "Cannot connect to daemon server."
      puts "Run: vpn-tool start --daemon"

      return
    end

    begin
      Process.kill("TERM", pid)

      puts "Daemon stopped (PID #{pid})."
    rescue Errno::ESRCH
      puts "Daemon not running."
    rescue Errno::EPERM
      abort "Error: permission denied for daemon PID #{pid}."
    rescue StandardError => e
      abort "Error stopping daemon: #{e.message}"
    ensure
      remove_file(DAEMON_PID_FILE) unless daemon_running?
    end
  end

  def daemon_status
    if daemon_running?
      socket = daemon_connection

      if socket
        socket.puts("STATUS")

        response = socket.gets

        socket.close

        puts(
          response || "Daemon running."
        )
      else
        puts(
          "Daemon PID #{daemon_pid} is running, " \
          "but cannot connect to daemon server."
        )
      end
    else
      puts "Daemon not running."
      puts "Cannot connect to daemon server."
      puts "Run: vpn-tool start --daemon"
    end
  end

  # ----------------------------------------------------------
  # API
  # ----------------------------------------------------------

  def api_request(method, endpoint, data = nil)
    uri = URI.join(BASE_URL, endpoint)

    request =
      case method.to_s.upcase
      when "GET"
        Net::HTTP::Get.new(uri)
      when "POST"
        Net::HTTP::Post.new(uri)
      else
        raise "Unsupported HTTP method: #{method}"
      end

    if data
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(data)
    end

    http = Net::HTTP.new(
      uri.host,
      uri.port
    )

    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 20
    http.read_timeout = 20

    response = http.request(request)

    puts response.body

    response
  rescue StandardError => e
    warn "API error: #{e.message}"
    nil
  end

  def api_get(endpoint)
    api_request(:get, endpoint)
  end

  def api_post(endpoint, data = {})
    api_request(:post, endpoint, data)
  end

  # ----------------------------------------------------------
  # CLI
  # ----------------------------------------------------------

  def build_cli
    cli = Commander.new

    cli.add_command(
      "version",
      "Show vpn-tool version"
    ) do
      puts "vpn-tool #{VERSION}"
    end

    # --------------------------------------------------------
    # Daemon commands
    # --------------------------------------------------------

    start =
      cli.add_command(
        "start",
        "Start the vpn-tool daemon"
      ) do |options, _args|
        unless options[:daemon]
          abort(
            "Error: --daemon is required.\n" \
            "Example: vpn-tool start --daemon"
          )
        end

        start_daemon
      end

    start.add_option(
      ["--daemon"],
      "Start daemon"
    )

    stop =
      cli.add_command(
        "stop",
        "Stop the vpn-tool daemon"
      ) do |options, _args|
        unless options[:daemon]
          abort(
            "Error: --daemon is required.\n" \
            "Example: vpn-tool stop --daemon"
          )
        end

        stop_daemon
      end

    stop.add_option(
      ["--daemon"],
      "Stop daemon"
    )

    status =
      cli.add_command(
        "status",
        "Show VPN status"
      ) do |options, _args|
        if options[:daemon]
          daemon_status
          next
        end

        exit 1 unless require_daemon

        api_get("/api/vpn/status")
      end

    status.add_option(
      ["--daemon"],
      "Show daemon status"
    )

    cli.add_command(
      "status-daemon",
      "Show daemon status"
    ) do
      daemon_status
    end

    # --------------------------------------------------------
    # VPN commands
    # --------------------------------------------------------

    cli.add_command(
      "countries",
      "List VPN countries"
    ) do
      exit 1 unless require_daemon

      api_get("/api/vpn/countries")
    end

    cli.add_command(
      "ip",
      "Show current IP"
    ) do
      exit 1 unless require_daemon

      api_get("/api/vpn/ip")
    end

    cli.add_command(
      "health",
      "Show API health"
    ) do
      exit 1 unless require_daemon

      api_get("/api/healthz")
    end

    connect =
      cli.add_command(
        "connect",
        "Connect to a VPN server"
      ) do |options, _args|
        exit 1 unless require_daemon

        unless require_login
          exit 1
        end

        country = options[:country]

        unless country
          abort(
            "Error: --country is required.\n" \
            "Example: vpn-tool connect --country US"
          )
        end

        country = country.upcase

        unless country.match?(/\A[A-Z]{2}\z/)
          abort(
            "Country must be a 2-letter country code."
          )
        end

        api_post(
          "/api/vpn/connect",
          {
            "countryCode" => country
          }
        )
      end

    connect.add_option(
      ["-c", "--country"],
      "Country <value>"
    )

    cli.add_command(
      "disconnect",
      "Disconnect from VPN"
    ) do
      exit 1 unless require_daemon

      if require_login
        api_post(
          "/api/vpn/disconnect",
          {}
        )
      end
    end

    # --------------------------------------------------------
    # Process commands
    # --------------------------------------------------------

    cli.add_command(
      "ps",
      "List running processes"
    ) do
      system("ps")
    end

    kill =
      cli.add_command(
        "kill",
        "Kill a process by PID"
      ) do |options, _args|
        pid = options[:pid]

        unless pid
          abort(
            "Error: --pid is required.\n" \
            "Example: vpn-tool kill --pid 1234"
          )
        end

        unless pid.match?(/\A\d+\z/)
          abort "Error: PID must be a number."
        end

        pid = pid.to_i

        if pid <= 0
          abort "Error: PID must be greater than 0."
        end

        begin
          Process.kill("TERM", pid)

          puts "Process #{pid} terminated."
        rescue Errno::ESRCH
          abort(
            "Error: process #{pid} was not found."
          )
        rescue Errno::EPERM
          abort(
            "Error: permission denied for process #{pid}."
          )
        rescue Errno::EINVAL
          abort "Error: invalid PID."
        rescue StandardError => e
          abort "Error: #{e.message}"
        end
      end

    kill.add_option(
      ["--pid"],
      "Process ID <value>"
    )

    # --------------------------------------------------------
    # Auth
    # --------------------------------------------------------

    auth =
      cli.add_command(
        "auth",
        "Authentication commands"
      )

    auth.add_subcommand("help") do
      puts <<~HELP
        Authentication commands:

        vpn-tool auth help
        vpn-tool auth register
        vpn-tool auth login
        vpn-tool auth status
        vpn-tool auth list
        vpn-tool auth reset
        vpn-tool auth logout
        vpn-tool auth remove
      HELP
    end

    auth.add_subcommand("register") do
      ensure_config

      if file_exists?(PIN_FILE)
        puts "PIN already registered."
        puts "Run: vpn-tool auth reset"
        next
      end

      pin = prompt("Enter new PIN: ")

      unless valid_pin?(pin)
        puts "PIN must be exactly 4 digits."
        next
      end

      confirm = prompt("Confirm new PIN: ")

      unless pin == confirm
        puts "PIN confirmation does not match."
        next
      end

      if write_file(PIN_FILE, pin)
        puts "PIN registered successfully."
      end
    end

    auth.add_subcommand("login") do
      puts "login works"

      next unless check_pin(
        "Enter PIN to login: "
      )

      if write_file(
        SESSION_FILE,
        Time.now.to_i.to_s
      )
        puts "Login successful."
      end
    end

    auth.add_subcommand("status") do
      puts "status works"

      next unless check_pin(
        "Enter PIN to status: "
      )

      puts(
        "PIN registered: #{file_exists?(PIN_FILE)}"
      )

      puts(
        "Session active: #{file_exists?(SESSION_FILE)}"
      )
    end

    # --------------------------------------------------------
    # Auth list
    #
    # Metadata only.
    # The PIN itself is never displayed.
    # --------------------------------------------------------

    auth.add_subcommand("list") do
      ensure_config

      puts "Authentication metadata:"
      puts
      puts "Config directory: #{CONFIG_DIR}"
      puts "PIN registered: #{file_exists?(PIN_FILE)}"
      puts "PIN file: #{PIN_FILE}"
      puts "Session active: #{file_exists?(SESSION_FILE)}"
      puts "Session file: #{SESSION_FILE}"

      if file_exists?(SESSION_FILE)
        session = read_file(SESSION_FILE)

        if session&.match?(/\A\d+\z/)
          puts(
            "Session created: #{Time.at(session.to_i)}"
          )
        else
          puts "Session created: unknown"
        end
      else
        puts "Session created: none"
      end

      puts "PIN value: hidden"
    end

    auth.add_subcommand("reset") do
      next unless check_pin(
        "Enter PIN to reset: "
      )

      pin = prompt("Enter new PIN: ")

      unless valid_pin?(pin)
        puts "PIN must be exactly 4 digits."
        next
      end

      confirm = prompt("Confirm new PIN: ")

      unless pin == confirm
        puts "PIN confirmation does not match."
        next
      end

      if write_file(PIN_FILE, pin)
        puts "PIN reset successfully."
      end
    end

    auth.add_subcommand("logout") do
      next unless check_pin(
        "Enter PIN to logout: "
      )

      remove_file(SESSION_FILE)

      puts "Logged out successfully."
    end

    auth.add_subcommand("remove") do
      next unless check_pin(
        "Enter PIN to remove: "
      )

      confirm = prompt(
        "Type REMOVE to continue: "
      )

      unless confirm == "REMOVE"
        puts "Remove cancelled."
        next
      end

      remove_file(PIN_FILE)
      remove_file(SESSION_FILE)

      puts "PIN and session removed."
    end

    cli
  end

  def help_text
    <<~HELP
      vpn-tool #{VERSION}

      Authentication:

        vpn-tool auth help
        vpn-tool auth register
        vpn-tool auth login
        vpn-tool auth status
        vpn-tool auth list
        vpn-tool auth reset
        vpn-tool auth logout
        vpn-tool auth remove

      VPN:

        vpn-tool countries
        vpn-tool connect --country US
        vpn-tool status
        vpn-tool ip
        vpn-tool disconnect
        vpn-tool health

      Process:

        vpn-tool ps
        vpn-tool kill --pid 1234

      Daemon:

        vpn-tool start --daemon
        vpn-tool stop --daemon
        vpn-tool status --daemon
        vpn-tool status-daemon

      Version:

        vpn-tool --version
        vpn-tool version
    HELP
  end

  def run(argv = ARGV)
    cli = build_cli

    if argv.empty?
      puts help_text
    elsif argv.first == "--version" ||
          argv.first == "-v"
      puts "vpn-tool #{VERSION}"
    elsif argv.first == "--help" ||
          argv.first == "-h"
      puts help_text
    else
      cli.parse(argv)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  VpnTool.run
end

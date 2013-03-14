require 'double_bag_ftps'
require 'net/ftp'

class TestClient

  extend Forwardable
  include FileUtils

  attr_accessor :tls_mode

  def initialize
    @tls_mode = :off
    @temp_dir = Ftpd::TempDir.make
    @templates = TestFileTemplates.new
  end

  def start
    @ftp = make_ftp
  end

  def close
    return unless @ftp
    @ftp.close
  end

  def_delegators :@ftp,
  :chdir,
  :connect,
  :delete,
  :getbinaryfile,
  :gettextfile,
  :help,
  :login,
  :ls,
  :mkdir,
  :nlst,
  :noop,
  :passive=,
  :pwd,
  :quit,
  :rename,
  :rmdir,
  :status,
  :system

  # Make a connection from a specific IP.  Net::FTP doesn't have a way
  # to force the local IP, so fake it here.

  def connect_from(source_ip, host, port)
    in_addr = Socket.pack_sockaddr_in(0, source_ip)
    out_addr = Socket.pack_sockaddr_in(port, host)
    socket = Socket.open(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    socket.bind(in_addr)
    socket.connect(out_addr)
    decorate_socket socket
    @ftp = make_ftp
    @ftp.set_socket(socket)
  end

  def raw(*command)
    @ftp.sendcmd command.compact.join(' ')
  end

  def get(mode, remote_path)
    method = "get#{mode}file"
    @ftp.send method, remote_path, local_path(remote_path)
  end

  def put(mode, remote_path)
    method = "put#{mode}file"
    @ftp.send method, local_path(remote_path), remote_path
  end

  def add_file(path)
    full_path = temp_path(path)
    mkdir_p File.dirname(full_path)
    File.open(full_path, 'wb') do |file|
      file.write @templates[File.basename(full_path)]
    end
  end

  def template(path)
    @templates[File.basename(path)]
  end

  def file_contents(path)
    File.open(temp_path(path), 'rb', &:read)
  end

  def xpwd
    response = raw('XPWD')
    response[/"(.+)"/, 1]
  end

  def store_unique(local_path, remote_path)
    command = ['STOU', remote_path].compact.join(' ')
    File.open(temp_path(local_path), 'rb') do |file|
      @ftp.storbinary command, file, Net::FTP::DEFAULT_BLOCKSIZE
    end
  end

  def append_binary(local_path, remote_path)
    command = ['APPE', remote_path].compact.join(' ')
    File.open(temp_path(local_path), 'rb') do |file|
      @ftp.storbinary command, file, Net::FTP::DEFAULT_BLOCKSIZE
    end
  end

  def append_text(local_path, remote_path)
    command = ['APPE', remote_path].compact.join(' ')
    File.open(temp_path(local_path), 'rb') do |file|
      @ftp.storlines command, file
    end
  end

  def connected?
    begin
      @ftp.noop
      true
    rescue Net::FTPTempError => e
      !!e.to_s =~ /^421/
    rescue EOFError
      false
    end
  end

  def set_option(option)
    raw "OPTS #{option}"
  end

  private

  RAW_METHOD_REGEX = /^send_(.*)$/

  def local_path(remote_path)
    temp_path(File.basename(remote_path))
  end

  def temp_path(path)
    File.expand_path(path, @temp_dir)
  end

  def make_ftp
    case @tls_mode
    when :off
      make_non_tls_ftp
    when :implicit
      make_tls_ftp(:implicit)
    when :explicit
      make_tls_ftp(:explicit)
    else
      raise "Unknown TLS mode: #{@tls_mode}"
    end
  end

  def make_tls_ftp(ftps_mode)
    ftp = DoubleBagFTPS.new
    context_opts = {
      :verify_mode => OpenSSL::SSL::VERIFY_NONE
    }
    ftp.ssl_context = DoubleBagFTPS.create_ssl_context(context_opts)
    ftp.ftps_mode = ftps_mode
    ftp
  end

  def make_non_tls_ftp
    Net::FTP.new
  end

  # Ruby 2.0's Ftp class is expecting a TCPSocket, not a Socket.  The
  # trouble comes with Ftp#close, which closes sockets by first doing
  # a shutdown, setting the read timeout, and doing a read.  Plain
  # Socket doesn't have those methods, so fake it.
  #
  # Plain socket _does_ have #close, but we short-circuit it, too,
  # because it takes a few seconds.  We're in a hurry when running
  # tests, and can afford to be a little sloppy when cleaning up.

  def decorate_socket(sock)

    def sock.shutdown(how)
      @shutdown = true
    end

    def sock.read_timeout=(seconds)
    end

    # Skip read after shutdown.  Prevents 2.0 from hanging in
    # Ftp#close

    def sock.read(*args)
      return if @shutdown
      super(*args)
    end

    def close
    end

  end

end

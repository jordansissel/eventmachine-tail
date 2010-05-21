#!/usr/bin/env ruby

require "eventmachine"
require "logger"

EventMachine.epoll if EventMachine.epoll?
EventMachine.kqueue = true if EventMachine.kqueue?

# Tail a file.
#
# Example
#   class Tailer < EventMachine::FileTail
#     def receive_data(data)
#       puts "Got #{data.length} bytes"
#     end
#   end
#
#   # Now add it to EM
#   EM.run do
#     EM.file_tail("/var/log/messages", Tailer)
#   end
#
#   # Or this way:
#   EM.run do
#     Tailer.new("/var/log/messages")
#   end
#
# See also: EventMachine::FileTail#receive_data
class EventMachine::FileTail
  # Maximum size to read at a time from a single file.
  CHUNKSIZE = 65536 

  # 
  #MAXSLEEP = 2

  # The path of the file being tailed
  attr_reader :path
  
  # Tail a file
  #
  # * path is a string file path to tail
  # * startpos is an offset to start tailing the file at. If -1, start at end of 
  # file.
  #
  # See also: EventMachine::file_tail
  #
  public
  def initialize(path, startpos=-1)
    @path = path
    @logger = Logger.new(STDOUT)
    @logger.level = ($DEBUG and Logger::DEBUG or Logger::WARN)
    @logger.debug("Tailing #{path} starting at position #{startpos}")

    @file = nil
    @fstat = File.stat(@path)

    if @fstat.directory?
      raise Errno::EISDIR.new(@path)
    end

    open
    watch { |what| notify(what) }
    if (startpos == -1)
      @file.sysseek(0, IO::SEEK_END)
    else
      @file.sysseek(startpos, IO::SEEK_SET)
      schedule_next_read
    end
  end # def initialize

  # This method is called when a tailed file has data read. 
  #
  # * data - string data read from the file.
  #
  # If you want to read lines from your file, you should use BufferedTokenizer
  # (which comes with EventMachine):
  #   class Tailer < EventMachine::FileTail
  #     def initialize(*args)
  #       super(*args)
  #       @buffer = BufferedTokenizer.new
  #     end
  #
  #     def receive_data(data)
  #       @buffer.extract(data).each do |line|
  #         # do something with 'line'
  #       end
  #     end  
  public
  def receive_data(data)
    raise NotImplementedError.new("#{self.class.name}#receive_data is not "\
      "implemented. Did you forget to implement this in your subclass or "\
      "module?")
  end # def receive_data

  # notify is invoked when the file you are tailing has been modified or
  # otherwise needs to be acted on.
  private
  def notify(status)
    @logger.debug("#{status} on #{path}")
    if status == :modified
      schedule_next_read
    elsif status == :moved
      # TODO(sissel): read to EOF, then reopen.
      open
    end
  end

  # Open (or reopen, if necessary) our file and schedule a read.
  private
  def open
    @file.close if @file
    begin
      @file = File.open(@path, "r")
    rescue Errno::ENOENT
      # no file found
      raise
    end

    @naptime = 0;
    @pos = 0
    schedule_next_read
  end

  # Watch our file.
  private
  def watch(&block)
    EventMachine::watch_file(@path, EventMachine::FileTail::FileWatcher, block)
  end

  # Schedule a read.
  private
  def schedule_next_read
    EventMachine::add_timer(@naptime) do
      read
    end
  end

  # Read CHUNKSIZE from our file and pass it to .receive_data()
  private
  def read
    begin
      data = @file.sysread(CHUNKSIZE)
      # Won't get here if sysread throws EOF
      @pos += data.length
      @naptime = 0
      receive_data(data)
      schedule_next_read
    rescue EOFError
      eof
    end
  end

  private
  def eof
    # TODO(sissel): This will be necessary if we can't use inotify or kqueue to
    # get notified of file changes
    #if @need_scheduling
      #@naptime = 0.100 if @naptime == 0
      #@naptime *= 2
      #@naptime = MAXSLEEP if @naptime > MAXSLEEP
      #@logger.info("EOF. Naptime: #{@naptime}")
    #end

    # TODO(sissel): should we schedule an fstat instead of doing it now?
    fstat = File.stat(@path)
    handle_fstat(fstat)
  end # def eof

  # Handle fstat changes appropriately.
  private
  def handle_fstat(fstat)
    if (fstat.ino != @fstat.ino)
      open # Reopen if the inode has changed
    elsif (fstat.rdev != @fstat.rdev)
      open # Reopen if the filesystem device changed
    elsif (fstat.size < @fstat.size)
      # Schedule a read if the file size has changed
      @logger.info("File likely truncated... #{path}")
      @file.sysseek(0, IO::SEEK_SET)
      schedule_next_read
    end
    @fstat = fstat
  end # def eof
end # class EventMachine::FileTail

# Internal usage only. This class is used by EventMachine::FileTail
# to watch files you are tailing.
#
# See also: EventMachine::FileTail#watch
class EventMachine::FileTail::FileWatcher < EventMachine::FileWatch
  def initialize(block)
    @logger = Logger.new(STDOUT)
    @logger.level = ($DEBUG and Logger::DEBUG or Logger::WARN)
    @callback = block
  end # def initialize

  def file_modified
    @callback.call(:modified)
  end # def file_modified

  def file_moved
    @callback.call(:moved)
  end # def file_moved

  def file_deleted
    @callback.call(:deleted)
  end # def file_deleted

  def unbind
    @callback.call(:unbind)
  end # def unbind
end # class EventMachine::FileTail::FileWatch < EventMachine::FileWatch

# Add EventMachine::file_tail
module EventMachine
  # Tail a file.
  #
  # path is the path to the file to tail.
  # handler should be a module implementing 'receive_data' or
  # must be a subclasses of EventMachine::FileTail
  def self.file_tail(path, handler=nil, *args)
    # This code mostly styled on what EventMachine does in many of it's other
    # methods.
    args = [path, *args]
    klass = klass_from_handler(EventMachine::FileTail, handler, *args);
    c = klass.new(*args)
    yield c if block_given?
    return c
  end # def self.file_tail
end # module EventMachine

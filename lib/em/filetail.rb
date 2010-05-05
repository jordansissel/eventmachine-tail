#!/usr/bin/env ruby

require "rubygems" if __FILE__ == $0
require "eventmachine"
require "logger"

EventMachine.epoll if EventMachine.epoll?

# Tail a file.
#
# Example
#   class Tailer < EventMachine::Tail
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
class EventMachine::FileTail
  CHUNKSIZE = 65536 
  MAXSLEEP = 2

  attr_reader :path
  
  # Tail a file
  #
  # path is a string file path
  # startpos is an offset to start tailing the file at. If -1, start at end of 
  # file.
  #
  public
  def initialize(path, startpos=-1)
    @path = path
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::WARN

    @fstat = File.stat(@path)

    if @fstat.directory?
      raise Errno::EISDIR.new(@path)
    end

    open
    watch
    if (startpos == -1)
      @file.sysseek(0, IO::SEEK_END)
    else
      @file.sysseek(startpos, IO::SEEK_SET)
      schedule_next_read
    end
  end # def initialize

  # notify is invoked by EventMachine when the file you are tailing
  # has been modified or otherwise needs to be acted on.
  #
  # You won't normally call this method.
  public
  def notify(status)
    @logger.debug("#{status} on #{path}")
    if status == :modified
      schedule_next_read
    elsif status == :moved
      # TODO(sissel): read to EOF, then reopen.
      open
    end
  end

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

  private
  def watch
    EventMachine::watch_file(@path, FileWatcher, self)
  end

  private
  def schedule_next_read
    EventMachine::add_timer(@naptime) do
      read
    end
  end

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

    # TODO(sissel): schedule an fstat instead of doing it now.
    fstat = File.stat(@path)
    handle_fstat(fstat)
  end # def eof

  private
  def handle_fstat(fstat)
    if (fstat.ino != @fstat.ino)
      open # Reopen if the inode has changed
    elsif (fstat.rdev != @fstat.rdev)
      open # Reopen if the filesystem device changed
    elsif (fstat.size < @fstat.size)
      @logger.info("File likely truncated... #{path}")
      @file.sysseek(0, IO::SEEK_SET)
      schedule_next_read
    end
    @fstat = fstat
  end # def eof
end # class EventMachine::FileTail

# Internal usage only
class EventMachine::FileTail::FileWatcher < EventMachine::FileWatch
  def initialize(filestream)
    @filestream = filestream
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::WARN
  end

  def file_modified
    @filestream.notify :modified
  end

  def file_moved
    @filestream.notify :moved
  end

  def file_deleted
    @filestream.notify :deleted
  end

  def unbind
    @filestream.notify :unbind
  end
end # class EventMachine::FileTail::FileWatch < EventMachine::FileWatch

# Add EventMachine::file_tail
module EventMachine
  
  # Tail a file.
  #
  # path is the path to the file to tail.
  # handler should be a module implementing 'receive_data' or
  # must be a subclasses of EventMachine::FileTail
  def self.file_tail(path, handler=nil, *args)
    args.unshift(path)
    klass = klass_from_handler(EventMachine::FileTail, handler, *args);
    c = klass.new(*args)
    yield c if block_given?
    return c
  end # def self.file_tail
end # module EventMachine

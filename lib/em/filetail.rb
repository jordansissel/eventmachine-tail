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
  def initialize(path, startpos=-1, &block)
    @path = path
    @logger = Logger.new(STDOUT)
    @logger.level = ($DEBUG and Logger::DEBUG or Logger::WARN)
    @logger.debug("Tailing #{path} starting at position #{startpos}")

    @file = nil
    read_file_metadata

    if block_given?
      @handler = block
      @buffer = BufferedTokenizer.new
    end

    if @filestat.directory?
      raise Errno::EISDIR.new(@path)
    end

    EventMachine::next_tick do
      open
      watch { |what| notify(what) }
      if (startpos == -1)
        @file.sysseek(0, IO::SEEK_END)
      else
        @file.sysseek(startpos, IO::SEEK_SET)
        schedule_next_read
      end
    end # EventMachine::next_tick
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
    if @handler # FileTail.new called with a block
      @buffer.extract(data).each do |line|
        @handler.call(self, line)
      end
    else
      raise NotImplementedError.new("#{self.class.name}#receive_data is not "\
        "implemented. Did you forget to implement this in your subclass or "\
        "module?")
    end
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
      # If the file was moved, treat it like EOF.
      eof
    end
  end

  # Open (or reopen, if necessary) our file and schedule a read.
  private
  def open
    @file.close if @file
    begin
      @logger.debug "Opening file #{@path}"
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
    @logger.debug "Starting watch on #{@path}"
    @watch = EventMachine::watch_file(@path, EventMachine::FileTail::FileWatcher, block)
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
    @logger.debug "#{self}: Reading..."
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
    begin
      read_file_metadata do |filestat, linkstat, linktarget|
        handle_fstat(filestat, linkstat, linktarget)
      end
    rescue Errno::ENOENT
      # The file disappeared. Wait for it to reappear.
      # This can happen if it was deleted or moved during log rotation.
      @logger.debug "File not found, waiting for it to reappear. (#{@path})"
      timer = EM::PeriodicTimer.new(0.250) do
        begin
          read_file_metadata do |filestat, linkstat, linktarget|
            handle_fstat(filestat, linkstat, linktarget)
          end
          timer.cancel
        rescue Errno::ENOENT
          # ignore
        end # begin/rescue ENOENT
      end # EM::PeriodicTimer
    end # begin/rescue ENOENT
  end # def eof

  private
  def read_file_metadata(&block)
    filestat = File.stat(@path)
    symlink_stat = nil
    symlink_target = nil
    if File.symlink?(@path)
      symlink_stat = File.lstat(@path)
      symlink_target = File.readlink(@path)
    end

    if block_given?
      yield filestat, symlink_stat, symlink_target
    end

    @filestat = filestat
    @symlink_stat = symlink_stat
    @symlink_target = symlink_target
  end # def read_file_metadata

  # Handle fstat changes appropriately.
  private
  def handle_fstat(filestat, symlinkstat, symlinktarget)
    if (filestat.ino != @filestat.ino or filestat.rdev != @filestat.rdev)
      EventMachine::next_tick do
        @logger.debug "Inode or device changed. Reopening..."
        @watch.stop_watching
        open # Reopen if the inode has changed
        watch { |what| notify(what) }
      end
    elsif (filestat.size < @filestat.size)
      # Schedule a read if the file size has changed
      @logger.info("File likely truncated... #{path}")
      @file.sysseek(0, IO::SEEK_SET)
      schedule_next_read
    end

    if symlinkstat.ino != @symlink_stat.ino
      EventMachine::next_tick do
        @logger.debug "Inode or device changed on symlink. Reopening..."
        @watch.stop_watching
        open # Reopen if the inode has changed
        watch { |what| notify(what) }
      end
    elsif symlinktarget != @symlink_target
      EventMachine::next_tick do
        @logger.debug "Symlink target changed. Reopening..."
        @watch.stop_watching
        open # Reopen if the inode has changed
        watch { |what| notify(what) }
      end
    end

  end # def eof

  def to_s
    return "#{self.class.name}(#{@path}) @ pos:#{@file.sysseek(0, IO::SEEK_CUR)}"
  end # def to_s
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
  #
  # For example:
  #   EM::file_tail("/var/log/messages", MyHandler)
  #
  # If a block is given, and the handler is not specified or does
  # not implement EventMachine::FileTail#receive_data, then it
  # will be called as such:
  #   EM::file_tail(...) do |filetail, line|
  #     # filetail is the FileTail instance watching the file
  #     # line is the line read from the file
  #   end
  def self.file_tail(path, handler=nil, *args, &block)
    # This code mostly styled on what EventMachine does in many of it's other
    # methods.
    args = [path, *args]
    klass = klass_from_handler(EventMachine::FileTail, handler, *args);
    c = klass.new(*args, &block)
    return c
  end # def self.file_tail
end # module EventMachine

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

  #MAXSLEEP = 2

  # The path of the file being tailed
  attr_reader :path

  # The current file read position
  attr_reader :position

  # Check interval when checking symlinks for changes. This is only useful
  # when you are actually tailing symlinks.
  attr_accessor :symlink_check_interval

  # Check interval for looking for a file if we are tailing it and it has
  # gone missing.
  attr_accessor :missing_file_check_interval
  
  # Tail a file
  #
  # * path is a string file path to tail
  # * startpos is an offset to start tailing the file at. If -1, start at end of 
  # file.
  #
  # If you want debug messages, run ruby with '-d' or set $DEBUG
  #
  # See also: EventMachine::file_tail
  #
  public
  def initialize(path, startpos=-1, &block)
    @path = path
    @logger = Logger.new(STDERR)
    @logger.level = ($DEBUG and Logger::DEBUG or Logger::WARN)
    @logger.debug("Tailing #{path} starting at position #{startpos}")

    @file = nil
    @want_eof_handling = false
    @want_read = false
    @want_reopen = false
    @reopen_on_eof = false
    @symlink_timer = nil
    @symlink_target = nil
    @symlink_stat = nil

    @symlink_check_interval = 1
    @missing_file_check_interval = 1

    read_file_metadata

    if @filestat.directory?
      raise Errno::EISDIR.new(@path)
    end

    if block_given?
      @handler = block
      @buffer = BufferedTokenizer.new
    end

    EventMachine::next_tick do
      open
      if (startpos == -1)
        @position = @file.sysseek(0, IO::SEEK_END)
        # TODO(sissel): if we don't have inotify or kqueue, should we
        # schedule a next read, here?
        # Is there a race condition between setting the file position and
        # watching given the two together are not atomic?
      else
        @position = @file.sysseek(startpos, IO::SEEK_SET)
        schedule_next_read
      end
      watch
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

  # This method is called when a tailed file reaches EOF.
  #
  # If you want to stop reading this file, call close(), otherwise
  # this eof is handled as normal tailing does. The default
  # EOF handler is to do nothing.
  public
  def eof
    # do nothing, subclassers should implement this.
  end # def eof

  # notify is invoked by EM::watch_file when the file you are tailing has been
  # modified or otherwise needs to be acted on.
  private
  def notify(status)
    @logger.debug("notify: #{status} on #{path}")
    if status == :modified
      schedule_next_read
    elsif status == :moved
      # read to EOF, then reopen.
      @reopen_on_eof = true
      schedule_next_read
    elsif status == :unbind
      # Do what?
    end
  end # def notify

  # Open (or reopen, if necessary) our file and schedule a read.
  private
  def open
    return if @closed
    @file.close if @file
    begin
      @logger.debug "Opening file #{@path}"
      @file = File.open(@path, "r")
    rescue Errno::ENOENT => e
      @logger.debug("File not found: '#{@path}' (#{e})")
      raise e
    end

    @naptime = 0
    @position = 0
    schedule_next_read
  end # def open

  # Close this filetail
  public
  def close
    @closed = true
    EM.schedule do
      @file.close if @file
    end
  end # def close

  # Watch our file.
  private
  def watch
    @watch.stop_watching if @watch
    @symlink_timer.cancel if @symlink_timer

    @logger.debug "Starting watch on #{@path}"
    callback = proc { |what| notify(what) }
    @watch = EventMachine::watch_file(@path, EventMachine::FileTail::FileWatcher, callback)
    watch_symlink if @symlink_target
  end # def watch

  # Watch a symlink
  # EM doesn't currently support watching symlinks alone (inotify follows
  # symlinks by default), so let's periodically stat the symlink.
  private
  def watch_symlink(&block)
    @symlink_timer.cancel if @symlink_timer

    @logger.debug "Launching timer to check for symlink changes since EM can't right now: #{@path}"
    @symlink_timer = EM::PeriodicTimer.new(@symlink_check_interval) do
      begin
        @logger.debug("Checking #{@path}")
        read_file_metadata do |filestat, linkstat, linktarget|
          handle_fstat(filestat, linkstat, linktarget)
        end
      rescue Errno::ENOENT
        # The file disappeared. Wait for it to reappear.
        # This can happen if it was deleted or moved during log rotation.
        @logger.debug "File not found, waiting for it to reappear. (#{@path})"
      end # begin/rescue ENOENT
    end # EM::PeriodicTimer
  end # def watch_symlink

  private
  def schedule_next_read
    if !@want_read
      @want_read = true
      EventMachine::add_timer(@naptime) do
        @want_read = false
        read
      end
    end # if !@want_read
  end # def schedule_next_read

  # Read CHUNKSIZE from our file and pass it to .receive_data()
  private
  def read
    return if @closed
    @logger.debug "#{self}: Reading..."
    begin
      data = @file.sysread(CHUNKSIZE)

      # Won't get here if sysread throws EOF
      @position += data.length
      @naptime = 0

      # Subclasses should implement receive_data
      receive_data(data)
      schedule_next_read
    rescue EOFError
      schedule_eof
    end
  end # def read

  # Do EOF handling on next EM iteration
  private
  def schedule_eof
    if !@want_eof_handling
      eof # Call our own eof event
      @want_eof_handling = true
      EventMachine::next_tick do
        handle_eof
      end # EventMachine::next_tick
    end # if !@want_eof_handling
  end # def schedule_eof

  private
  def schedule_reopen
    if !@want_reopen
      EventMachine::next_tick do
        @want_reopen = false
        open
        watch
      end
    end # if !@want_reopen
  end # def schedule_reopen

  private
  def handle_eof
    @want_eof_handling = false

    if @reopen_on_eof
      @reopen_on_eof = false
      schedule_reopen
    end

    # EOF actions:
    # - Check if the file inode/device is changed
    # - If symlink, check if the symlink has changed
    # - Otherwise, do nothing
    begin
      read_file_metadata do |filestat, linkstat, linktarget|
        handle_fstat(filestat, linkstat, linktarget)
      end
    rescue Errno::ENOENT
        # The file disappeared. Wait for it to reappear.
        # This can happen if it was deleted or moved during log rotation.
      timer = EM::PeriodicTimer.new(@missing_file_check_interval) do
        begin
          read_file_metadata do |filestat, linkstat, linktarget|
            handle_fstat(filestat, linkstat, linktarget)
          end
          timer.cancel
        rescue Errno::ENOENT
          # The file disappeared. Wait for it to reappear.
          # This can happen if it was deleted or moved during log rotation.
          @logger.debug "File not found, waiting for it to reappear. (#{@path})"
        end # begin/rescue ENOENT
      end # EM::PeriodicTimer
    end # begin/rescue ENOENT
  end # def handle_eof

  private
  def read_file_metadata(&block)
    filestat = File.stat(@path)
    symlink_stat = nil
    symlink_target = nil

    if File.symlink?(@path)
      symlink_stat = File.lstat(@path) rescue nil
      symlink_target = File.readlink(@path) rescue nil
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
    # If the symlink target changes, the filestat.ino is very likely to have
    # changed since that is the stat on the resolved file (that the link points
    # to). However, we'll check explicitly for the symlink target changing
    # for better debuggability.
    if symlinktarget
      if symlinkstat.ino != @symlink_stat.ino
        @logger.debug "Inode or device changed on symlink. Reopening..."
        @reopen_on_eof = true
        schedule_next_read
      elsif symlinktarget != @symlink_target
        @logger.debug "Symlink target changed. Reopening..."
        @reopen_on_eof = true
        schedule_next_read
      end 
    elsif (filestat.ino != @filestat.ino or filestat.rdev != @filestat.rdev)
      @logger.debug "Inode or device changed. Reopening..."
      @logger.debug filestat
      @reopen_on_eof = true
      schedule_next_read
    elsif (filestat.size < @filestat.size)
      # If the file size shrank, assume truncation and seek to the beginning.
      @logger.info("File likely truncated... #{path}")
      @position = @file.sysseek(0, IO::SEEK_SET)
      schedule_next_read
    end
  end # def handle_fstat

  def to_s
    return "#{self.class.name}(#{@path}) @ pos:#{@position}"
  end # def to_s
end # class EventMachine::FileTail

# Internal usage only. This class is used by EventMachine::FileTail
# to watch files you are tailing.
#
# See also: EventMachine::FileTail#watch
class EventMachine::FileTail::FileWatcher < EventMachine::FileWatch
  def initialize(block)
    @logger = Logger.new(STDERR)
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

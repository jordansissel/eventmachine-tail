#!/usr/bin/env ruby

require "set"
require "eventmachine"
require "logger"
require "em/filetail"

# A file glob pattern watcher for EventMachine.
#
# If you are unfamiliar with globs, see Wikipedia:
# http://en.wikipedia.org/wiki/Glob_(programming)
#
# Any glob supported by Dir#glob will work with
# this class.
#
# This class will allow you to get notified whenever a file
# is created or deleted that matches your glob.
#
#
class EventMachine::FileGlobWatch
  def initialize(pathglob, interval=60)
    @pathglob = pathglob
    #@handler = handler
    @files = Set.new
    @watches = Hash.new
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO

    # We periodically check here because it is easier than writing our own glob
    # parser (so we can smartly watch globs like /foo/*/bar*/*.log)
    #
    # Reasons to fix this -
    # This will likely perform badly on globs that result in a large number of
    # files.
    EM.next_tick do
      find_files
      EM.add_periodic_timer(interval) do
        find_files
      end
    end
  end # def initialize

  private
  def find_files
    @logger.info("Searching for files in #{@pathglob}")
    list = Set.new(Dir.glob(@pathglob))
    list.each do |path|
      next if @files.include?(path)
      add(path)
    end

    (@files - list).each do |missing|
      remove(missing)
    end
  end # def find_files

  public
  def remove(path)
    @files.delete(path)
    @watches.delete(path)
    file_removed(path)
  end

  private
  def add(path)
    @logger.info "Watching #{path}"
    @files.add(path)

    # If EventMachine::watch_file fails, that's ok, I guess.
    # We'll still find the file 'missing' from the next glob attempt.
    begin
      @watches[path] = EventMachine::watch_file(path, GlobFileWatch, self)
    rescue Errno::EACCES => e
      @logger.warn(e)
    end
    file_found(path)
  end # def watch

  private
  class GlobFileWatch < EventMachine::FileWatch
    def initialize(globwatch)
      @globwatch = globwatch
    end

    def file_moved
      stop_watching
      @globwatch.remove(path)
    end

    def file_deleted
      @globwatch.remove(path)
    end
  end # class GlobFileWatch < EventMachine::FileWatch
end # class EventMachine::FileGlobWatch

class EventMachine::FileGlobWatchTail < EventMachine::FileGlobWatch
  def initialize(path, handler=nil, *args)
    super(path, *args)
    @handler = handler
    @args = args
  end

  def file_found(path)
    begin
      EventMachine::file_tail(path, @handler, *@args)
    rescue Errno::EACCES => e
      file_error(path, e)
    rescue Errno::EISDIR => e
      file_error(path, e)
    end
  end

  def file_removed(path)
    # Nothing to do
  end

  def file_error(path, e)
    $stderr.puts "#{e.class} while trying to tail #{path}"
    # Ignore by default
  end
end # class EventMachine::FileGlobWatchHandler

# Add EventMachine::glob_tail
module EventMachine
  def self.glob_tail(glob, handler=nil, *args)
    handler = EventMachine::FileGlobWatch if handler == nil
    args.unshift(glob)
    klass = klass_from_handler(EventMachine::FileGlobWatchTail, handler, *args)
    c = klass.new(*args)
    yield c if block_given?
    return c
  end
end

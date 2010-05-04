#!/usr/bin/env ruby

require "set"
require "eventmachine"
require "logger"
require "em/filetail"

class EventMachine::FileGlobWatch
  def initialize(pathglob, handler, interval=60)
    @pathglob = pathglob
    @handler = handler
    @files = Set.new
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::WARN

    EM.next_tick do
      find_files
      EM.add_periodic_timer(interval) do
        find_files
      end
    end
  end # def initialize

  def find_files
    list = Set.new(Dir.glob(@pathglob))
    list.each do |path|
      next if @files.include?(path)
      watch(path)
    end

    (@files - list).each do |missing|
      @files.delete(missing)
      @handler.file_removed(missing)
    end
  end # def find_files

  def watch(path)
    @logger.info "Watching #{path}"
    @files.add(path)
    @handler.file_found(path)
  end # def watch
end # class EventMachine::FileGlobWatch

class EventMachine::FileGlobWatchTail
  def initialize(handler=nil, *args)
    @handler = handler
    @args = args
  end

  def file_found(path)
    EventMachine::file_tail(path, @handler, *@args)
  end

  def file_removed(path)
    # Nothing to do
  end
end # class EventMachine::FileGlobWatchHandler

module EventMachine
  def self.glob_tail(glob, handler=nil, *args)
    handler = EventMachine::FileGlobHandler if handler == nil
    klass = klass_from_handler(EventMachine::FileGlobWatchTail, handler, *args)
    c = klass.new(*args)
    yield c if block_given?
    return c
  end
end

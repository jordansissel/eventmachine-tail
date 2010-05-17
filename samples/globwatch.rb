#!/usr/bin/env ruby

require "rubygems"
require "eventmachine"
require "eventmachine-tail"

class Watcher < EventMachine::FileGlobWatch
  def initialize(pathglob, interval=5)
    super(pathglob, interval)
  end

  def file_deleted(path)
    puts "Removed: #{path}"
  end

  def file_found(path)
    puts "Found: #{path}"
  end
end # class Watcher

EM.run do
  Watcher.new("/var/log/*")
end

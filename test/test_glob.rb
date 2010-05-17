#!/usr/bin/env ruby

require 'rubygems'
$:.unshift "#{File.dirname(__FILE__)}/../lib"
require 'eventmachine-tail'
require 'tempfile'
require 'test/unit'
require 'timeout'
require 'tmpdir'

require 'testcase_helpers'

class Watcher < EventMachine::FileGlobWatch
  def initialize(path, interval, data, testobj)
    super(path, interval)
    @data = data
    @testobj = testobj
  end # def initialize

  def file_found(path)
    # Use .include? here because files aren't going to be found in any
    # particular order.
    @testobj.assert(@data.include?(path), "Expected #{path} in \n#{@data.join("\n")}")
    @data.delete(path)
    @testobj.finish if @data.length == 0
  end

  def file_removed(path)
    @testobj.assert(@data.include?(path), "Expected #{path} in \n#{@data.join("\n")}")
    @data.delete(path)
    @testobj.finish if @data.length == 0
  end
end # class Reader

class TestGlobWatcher < Test::Unit::TestCase
  include EventMachineTailTestHelpers
  SLEEPMAX = 2

  def setup
    @watchinterval = 0.2
    @dir = Dir.mktmpdir
    @data = []
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}"
    @data << "#{@dir}/#{rand}.gz"
    @data << "#{@dir}/#{rand}.gz"
    @data << "#{@dir}/#{rand}.tar.gz"
  end # def setup

  def teardown
    @data.each do |file|
      #puts "Deleting #{file}"
      File.delete(file) rescue nil
    end
    Dir.delete(@dir)
  end # def teardown

  def finish
    EM.stop_event_loop
  end

  def test_glob_finds_existing_files
    EM.run do
      abort_after_timeout(SLEEPMAX * @data.length + 10)

      @data.each do |path|
        File.new(path, "w").close
      end
      EM::watch_glob("#{@dir}/*", Watcher, @watchinterval, @data.clone, self)
    end # EM.run
  end # def test_glob_finds_existing_files

  # This test should run slow. We are trying to ensure that
  # our file_tail correctly reads data slowly fed into the file
  # as 'tail -f' would.
  def test_glob_finds_newly_created_files_at_runtime
    EM.run do
      abort_after_timeout(SLEEPMAX * @data.length + 10)

      EM::watch_glob("#{@dir}/*", Watcher, @watchinterval, @data.clone, self)
      datacopy = @data.clone
      timer = EM::PeriodicTimer.new(0.2) do
        #puts "Creating: #{datacopy.first}"
        File.new(datacopy.shift, "w")
        sleep(rand * SLEEPMAX)
        timer.cancel if datacopy.length == 0
      end
    end # EM.run
  end # def test_glob_finds_newly_created_files_at_runtime
end # class TestGlobWatcher


#!/usr/bin/env ruby

require 'rubygems'
$:.unshift "#{File.dirname(__FILE__)}/../lib"
require 'eventmachine-tail'
require 'tempfile'
require 'test/unit'
require 'timeout'
require 'testcase_helpers.rb'


# Generate some data
DATA = (1..10).collect { |i| rand.to_s }
SLEEPMAX = 1

class Reader < EventMachine::FileTail
  def initialize(path, startpos=-1, testobj=nil)
    super(path, startpos)
    @data = DATA.clone
    @buffer = BufferedTokenizer.new
    @testobj = testobj
    @lineno = 0
  end # def initialize

  def receive_data(data)
    @buffer.extract(data).each do |line|
      @lineno += 1
      expected = @data.shift
      @testobj.assert_equal(expected, line,
          "Expected '#{expected}' on line #{@lineno}, but got '#{line}'")
    end # @buffer.extract
  end # def receive_data

  # This effectively tests EOF handling by requiring it to work in order
  # for the tests to pass.
  def eof
    if @data.length == 0
      close
      @testobj.finish
    end
  end # def eof
end # class Reader

class TestFileTail < Test::Unit::TestCase
  include EventMachineTailTestHelpers

  # This test should run slow. We are trying to ensure that
  # our file_tail correctly reads data slowly fed into the file
  # as 'tail -f' would.
  def test_filetail
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    EM.run do
      abort_after_timeout(DATA.length * SLEEPMAX + 10)

      EM::file_tail(tmp.path, Reader, -1, self)
      timer = EM::PeriodicTimer.new(0.2) do
        tmp.puts data.shift
        tmp.flush
        sleep(rand * SLEEPMAX)
        timer.cancel if data.length == 0
      end
    end # EM.run
  end # def test_filetail

  def test_filetail_close
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    data.each { |i| tmp.puts i }
    tmp.flush

    EM.run do
      abort_after_timeout(2)

      ft = EM::file_tail(tmp.path, Reader, -1, self)
      ft.close
      timer = EM::PeriodicTimer.new(0.2) do
        timer.cancel and finish if ft.closed?
      end
    end # EM.run
  end # def test_filetail_close

  def test_filetail_with_seek
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    data.each { |i| tmp.puts i }
    tmp.flush
    EM.run do
      abort_after_timeout(2)

      # Set startpos of 0 (beginning of file)
      EM::file_tail(tmp.path, Reader, 0, self)
    end # EM.run
  end # def test_filetail

  def test_filetail_with_block
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    EM.run do
      abort_after_timeout(DATA.length * SLEEPMAX + 10)

      lineno = 0
      EM::file_tail(tmp.path) do |filetail, line|
        lineno += 1
        expected = data.shift
        assert_equal(expected, line,
                     "Expected '#{expected}' on line #{@lineno}, but got '#{line}'")
        finish if data.length == 0
      end

      data_copy = data.clone
      timer = EM::PeriodicTimer.new(0.2) do
        tmp.puts data_copy.shift
        tmp.flush
        sleep(rand * SLEEPMAX)
        timer.cancel if data_copy.length == 0
      end
    end # EM.run
  end # def test_filetail_with_block

  def test_filetail_tracks_renames
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    filename = tmp.path

    data_copy = data.clone

    # Write first so the first read happens immediately
    tmp.puts data_copy.shift
    tmp.flush
    EM.run do
      abort_after_timeout(DATA.length * SLEEPMAX + 10)

      lineno = 0
      # Start at file position 0.
      EM::file_tail(tmp.path, nil, 0) do |filetail, line|
        lineno += 1
        expected = data.shift
        #puts "Got #{lineno}: #{line}"
        assert_equal(expected, line,
                     "Expected '#{expected}' on line #{lineno}, but got '#{line}'")
        finish if data.length == 0

        # Start a timer on the first read.
        # This is to ensure we have the file tailing before
        # we try to rename.
        if lineno == 1
          timer = EM::PeriodicTimer.new(0.2) do
            value = data_copy.shift
            tmp.puts value
            tmp.flush
            sleep(rand * SLEEPMAX)

            # Rename the file, create a new one in it's place.
            # This is to simulate log rotation, etc.
            path_newname = "#{filename}_#{value}"
            File.rename(filename, path_newname)
            File.delete(path_newname)
            tmp = File.open(filename, "w")
            timer.cancel if data_copy.length == 0
          end # timer
        end # if lineno == 1
      end # EM::filetail(...)
    end # EM.run

    File.delete(filename)
  end # def test_filetail_tracks_renames

  def test_filetail_tracks_symlink_changes
    to_delete = []
    link = Tempfile.new("testlink")
    File.delete(link.path)
    to_delete << link
    tmp = Tempfile.new("testfiletail")
    to_delete << tmp
    data = DATA.clone
    File.symlink(tmp.path, link.path)

    data_copy = data.clone

    # Write first so the first read happens immediately
    tmp.puts data_copy.shift
    tmp.flush
    EM.run do
      abort_after_timeout(DATA.length * SLEEPMAX + 10)

      lineno = 0
      # Start at file position 0.
      EM::file_tail(link.path, nil, 0) do |filetail, line|
        # This needs to be less than the interval at which we are changing symlinks.
        filetail.symlink_check_interval = 0.1

        lineno += 1
        expected = data.shift
        puts "Got #{lineno}: #{line}" if $debug
        assert_equal(expected, line,
                     "Expected '#{expected}' on line #{lineno}, but got '#{line}'")
        finish if data.length == 0

        # Start a timer on the first read.
        # This is to ensure we have the file tailing before
        # we try to rename.
        if lineno == 1
          timer = EM::PeriodicTimer.new(0.2) do
            value = data_copy.shift
            tmp.puts value
            tmp.flush
            sleep(rand * SLEEPMAX)

            # Make a new file and update the symlink to point to it.
            # This is to simulate log rotation, etc.
            tmp.close
            tmp = Tempfile.new("testfiletail")
            to_delete << tmp
            File.delete(link.path)
            File.symlink(tmp.path, link.path)
            puts "#{tmp.path} => #{link.path}" if $debug
            timer.cancel if data_copy.length == 0
          end # timer
        end # if lineno == 1
      end # EM::filetail(...)
    end # EM.run

    to_delete.each do |f|
      File.delete(f.path)
    end
  end # def test_filetail_tracks_renames

  def test_encoding
    return if RUBY_VERSION < '1.9.0'
    tmp = Tempfile.new("testfiletail")
    data = DATA.clone
    EM.run do
      abort_after_timeout(1)

      EM::file_tail(tmp.path) do |filetail, line|
        assert_equal(Encoding.default_external, line.encoding,
                     "Expected the read data to have the encoding specified in Encoding.default_external (#{Encoding.default_external}, but was #{line.encoding})")
        finish
      end

      EM.next_tick do
        tmp.puts(data.shift)
        tmp.flush
      end
    end # EM.run
  end # def test_encoding
end # class TestFileTail


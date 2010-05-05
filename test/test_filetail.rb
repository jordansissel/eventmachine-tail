#!/usr/bin/env ruby

$:.unshift "../lib"
require 'rubygems'
require 'eventmachine-tail'
require 'test/unit'

DATA = (1000..1010).to_a.collect { |i| i.to_s }
SLEEPMAX = 2

class Reader < EventMachine::FileTail
  def initialize(path, startpos=-1, testobj=nil)
    super(path, startpos)
    @data = DATA.clone
    @buffer = BufferedTokenizer.new
    @testobj = testobj
  end # def initialize

  def receive_data(data)
    @buffer.extract(data).each do |line|
      expected = @data.shift
      puts expected
      @testobj.assert_equal(expected, line)
      if @data.length == 0
        EM.stop_event_loop
      end
    end # @buffer.extract
  end # def receive_data
end # class Reader

class TestFileTail < Test::Unit::TestCase

  # This test should run slow. We are trying to ensure that
  # our file_tail correctly reads data slowly fed into the file
  # as 'tail -f' would.
  def test_filetail
    require 'tempfile'
    require 'timeout'

    Timeout.timeout(DATA.length * SLEEPMAX + 10) do
      tmp = Tempfile.new("testfiletail")
      data = DATA.clone
      EM.run do
        EM::file_tail(tmp.path, Reader, -1, self)
          
        timer = EM::PeriodicTimer.new(0.2) do
          tmp.puts data.shift
          tmp.flush
          sleep(rand * SLEEPMAX)
          timer.cancel if data.length == 0
        end
      end # EM.run
    end # Timeout.timeout
  end # def test_filetail

  def test_filetail_with_seek
    require 'tempfile'
    require 'timeout'

    Timeout.timeout(2) do
      tmp = Tempfile.new("testfiletail")
      data = DATA.clone
      data.each { |i| tmp.puts i }
      tmp.flush
      EM.run do
        # Set startpos of 0
        EM::file_tail(tmp.path, Reader, 0, self)
      end # EM.run
    end # Timeout.timeout
  end # def test_filetail
end # class TestFileTail


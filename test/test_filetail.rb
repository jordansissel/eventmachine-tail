#!/usr/bin/env ruby

$:.unshift "../lib"
require 'rubygems'
require 'eventmachine-tail'
require 'test/unit'

DATA = (1000..1010).to_a.collect { |i| i.to_s }
SLEEPMAX = 2

class Reader < EventMachine::FileTail
  def initialize(path, testobj)
    super(path)
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
    end
  end # def receive_data
end # class Reader

class TestFileTail < Test::Unit::TestCase
  def test_filetail
    require 'tempfile'
    require 'timeout'

    Timeout.timeout(DATA.length * SLEEPMAX + 10) do
      tmp = Tempfile.new("testfiletail")
      data = DATA.clone
      EM.run do
        EM::file_tail(tmp.path, Reader, self)
          
        timer = EM::PeriodicTimer.new(0.2) do
          tmp.puts data.shift
          tmp.flush
          sleep(rand * SLEEPMAX)
          timer.cancel if data.length == 0
        end
      end # EM.run
    end # Timeout.timeout
  end # def test_filetail
end # class TestFileTail


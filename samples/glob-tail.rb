#!/usr/bin/env ruby
#
# Sample that uses eventmachine-tail to watch a file or set of files.
# Basically, this example implements 'tail -f' but can accept globs
# that are also watched.
#
# For example, '/var/log/*.log' will be periodically watched for new
# matching files which will additionally be watched.
#
# Usage example:
#   glob-tail.rb "/var/log/*.log" "/var/log/httpd/*.log"
#
# (Important to use quotes or otherwise escape the '*' chars, otherwise
#  your shell will interpret them)

require "rubygems"
require "eventmachine"
require "eventmachine-tail"
require "ap" # from rubygem awesome_print

class Reader < EventMachine::FileTail
  def initialize(*args)
    super(*args)
    @buffer = BufferedTokenizer.new
  end

  def receive_data(data)
    @buffer.extract(data).each do |line|
      ap [path, line]
    end
  end
end

def main(args)
  if args.length == 0
    puts "Usage: #{$0} <path_or_glob> [path_or_glob2] [...]"
    return 1
  end

  EventMachine.run do
    #handler = EventMachine::FileGlobWatchTail.new(Reader)
    args.each do |path|
      EventMachine::FileGlobWatchTail.new(path, Reader)
      #EventMachine::FileGlobWatch.new(path, handler)
      #EventMachine::file_tail(path, handler)
    end
  end
end # def main

exit(main(ARGV))

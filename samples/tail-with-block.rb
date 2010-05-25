#!/usr/bin/env ruby
#
# Simple 'tail -f' example.
# Usage example:
#   tail.rb /var/log/messages

require "rubygems"
require "eventmachine"
require "eventmachine-tail"

def main(args)
  if args.length == 0
    puts "Usage: #{$0} <path> [path2] [...]"
    return 1
  end

  EventMachine.run do
    args.each do |path|
      EventMachine::file_tail(path) do |filetail, line|
        # filetail is the 'EventMachine::FileTail' instance for this file.
        # line is the line read from thefile.
        # this block is invoked for every line read.
        puts line
      end
    end
  end
end # def main

exit(main(ARGV))

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
        puts line
      end
    end
  end
end # def main

exit(main(ARGV))

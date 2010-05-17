task :default => [:package]

task :test do
  system("cd test; ruby test_filetail.rb")
end

task :package => [:test]  do
  system("gem build eventmachine-tail.gemspec")
end

task :publish do
  latest_gem = %x{ls -t eventmachine-tail*.gem}.split("\n").first
  system("gem push #{latest_gem}")
end

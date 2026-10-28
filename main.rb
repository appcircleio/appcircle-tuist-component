require 'open3'
require 'digest'
require 'fileutils'

DEFAULT_TUIST_VERSION = "4.214.0"

def env_has_key(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def runCommand(command)
    puts "@@[command] #{command}"
    status = nil
    stdout_str = nil
    stderr_str = nil
    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
      stdout.each_line do |line|
        puts line
      end
      stdout_str = stdout.read
      stderr_str = stderr.read
      status = wait_thr.value
    end
  
    unless status.success?
      raise stderr_str
    end
end

tuist_path = env_has_key("AC_TUIST_PATH") || abort("Missing AC_TUIST_PATH")
# Used when AC_TUIST_VERSION is empty: the version that `brew install tuist` installed when this was pinned.
tuist_version = env_has_key("AC_TUIST_VERSION") || DEFAULT_TUIST_VERSION
tuist_base_url = (env_has_key("AC_TUIST_BASE_URL") || "https://github.com/tuist/tuist/releases/download").chomp("/")
ENV["TUIST_STATS_OPT_OUT"] = "1"

installed_version = begin
  `tuist version 2>/dev/null`.strip.split("\n").last
rescue Errno::ENOENT
  nil
end

if installed_version == tuist_version
  puts "Tuist #{tuist_version} is already installed, skipping download."
else
  install_dir = "#{Dir.home}/tuist/#{tuist_version}"
  unless File.exist?("#{install_dir}/tuist")
    release_url = "#{tuist_base_url}/#{tuist_version}"
    puts "Downloading Tuist #{tuist_version} from #{release_url}/tuist.zip"
    runCommand("curl -fsSL --retry 3 -o SHASUMS256.txt #{release_url}/SHASUMS256.txt")
    expected_checksum = File.readlines("SHASUMS256.txt").map(&:split).find { |_, file| file.to_s.sub(%r{\A\./}, "") == "tuist.zip" }&.first
    abort("tuist.zip is not listed in SHASUMS256.txt of Tuist #{tuist_version}") unless expected_checksum
    runCommand("curl -fsSL --retry 3 -o tuist.zip #{release_url}/tuist.zip")
    checksum = Digest::SHA256.file("tuist.zip").hexdigest
    abort("Checksum mismatch for tuist.zip: expected #{expected_checksum}, got #{checksum}") unless checksum == expected_checksum
    puts "Checksum verified: #{checksum}"
    FileUtils.mkdir_p(install_dir)
    runCommand("ditto -x -k tuist.zip #{install_dir}")
    FileUtils.rm_f(["tuist.zip", "SHASUMS256.txt"])
  end
  ENV["PATH"] = "#{install_dir}:#{ENV["PATH"]}"
end

env_file_path = env_has_key("AC_ENV_FILE_PATH")
if env_file_path
  open(env_file_path, 'a') { |f|
    f.puts "PATH=#{ENV["PATH"]}"
    f.puts "TUIST_STATS_OPT_OUT=1"
  }
end

runCommand("tuist generate -p #{tuist_path}")
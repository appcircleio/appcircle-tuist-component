require 'open3'
require 'fileutils'

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

runCommand("brew tap tuist/tuist")
options = ""
tuist_path = env_has_key("AC_TUIST_PATH")
project_only = env_has_key("AC_TUIST_PROJECT_ONLY") || "false"
tuist_version = env_has_key("AC_TUIST_VERSION")
tuist_build = env_has_key("AC_TUIST_BUILD") || "false"
tuist_test = env_has_key("AC_TUIST_TEST") || "false"
tuist_fetch = env_has_key("AC_TUIST_FETCH") || "false"
tuist_clean = env_has_key("AC_TUIST_CLEAN") || "false"


if !tuist_version
  runCommand("brew install tuist")
else
  runCommand("brew install tuist@#{tuist_version}")
end

if tuist_path
  options += " -p #{tuist_path}"
end
if project_only == "true"
  options += " -P"
end

puts "Tuist Installed. Running related Tuist commands."

runCommand("tuist fetch #{options}") if tuist_fetch "true"
runCommand("tuist generate #{options}") "true"
runCommand("tuist clean #{options}") if tuist_clean "true"
runCommand("tuist build #{options}") if tuist_build "true"
runCommand("tuist test #{options}") if tuist_test "true"

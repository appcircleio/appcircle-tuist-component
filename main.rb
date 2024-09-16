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

runCommand("brew install tap/tuist")
options = ""
tuist_path = env_has_key("AC_TUIST_PATH")
project_only = env_has_key("AC_TUIST_PROJECT_ONLY") || "false"
tuist_version = env_has_key("AC_TUIST_VERSION")
tuist_build = env_has_key("AC_TUIST_BUILD") || "false"
tuist_test = env_has_key("AC_TUIST_TEST") || "false"
tuist_build_scheme = env_has_key("AC_TUIST_BUILD_SCHEME")
tuist_test_scheme = env_has_key("AC_TUIST_TEST_SCHEME")
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

runCommand("tuist fetch") if tuist_fetch
runCommand("tuist generate #{options}")
runCommand("tuist clean #{options}") if tuist_clean
runCommand("tuist build #{options}") if tuist_build
runCommand("tuist test #{options}") if tuist_test
runCommand("tuist build #{options} #{tuist_build_scheme}") if tuist_build_scheme
runCommand("tuist test #{options} #{tuist_test_scheme}") if tuist_test_scheme

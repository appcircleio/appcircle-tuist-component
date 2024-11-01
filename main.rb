require 'open3'

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
tuist_path = env_has_key("AC_TUIST_PATH") || abort("Missing AC_TUIST_PATH")
tuist_version = env_has_key("AC_TUIST_VERSION")
spec_version = ""

if tuist_version
  spec_version = "@#{tuist_version}"
end
  
runCommand("brew install tuist#{spec_version}")

runCommand("tuist generate -p #{tuist_path}")
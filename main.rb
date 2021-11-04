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
runCommand("curl -Ls https://install.tuist.io | bash")
options = ""
tuist_path = env_has_key("AC_TUIST_PATH")
project_only = env_has_key("AC_TUIST_PROJECT_ONLY") || "false"
if tuist_path
  options += " -p #{tuist_path}"
end
if project_only == "true"
  options += " -P"
end
runCommand("tuist generate #{options}")
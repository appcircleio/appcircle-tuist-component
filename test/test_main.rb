# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'stringio'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Every variable the step reads or writes. PATH, HOME and TUIST_STATS_OPT_OUT
# are included because the step changes them (or reads them via Dir.home).
STEP_ENV_KEYS    = %w[AC_TUIST_PATH AC_TUIST_VERSION AC_TUIST_BASE_URL AC_ENV_FILE_PATH].freeze
MUTATED_ENV_KEYS = %w[PATH HOME TUIST_STATS_OPT_OUT].freeze
DEFAULT_BASE_URL = 'https://github.com/tuist/tuist/releases/download'
CURL             = 'curl -fsSL --retry 3'
ZIP_BODY         = "fake tuist.zip payload\n"
ZIP_SHA256       = Digest::SHA256.hexdigest(ZIP_BODY)

# Saves and clears every variable the step reads, runs the block, then restores
# them together with the variables the step mutates.
def with_clean_env
  keys = STEP_ENV_KEYS + MUTATED_ENV_KEYS
  old = keys.to_h { |k| [k, ENV[k]] }
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  ENV.delete('TUIST_STATS_OPT_OUT')
  yield
ensure
  keys.each { |k| ENV.delete(k) }
  old.each { |k, v| ENV[k] = v unless v.nil? }
end

def fake_status(success)
  double('Process::Status', success?: success)
end

# Stubs Open3.popen3 so no real command runs. Each call records the command and
# yields fake stdin/stdout/stderr streams plus a wait thread. The handler maps
# the command to [stdout, stderr, success]; without one every command succeeds
# silently.
def stub_popen3(recorder: nil, &handler)
  allow(Open3).to receive(:popen3) do |cmd, &block|
    recorder&.<<(cmd)
    stdout, stderr, success = handler ? handler.call(cmd) : ['', '', true]
    wait_thr = double('Process::Waiter', value: fake_status(success))
    block.call(StringIO.new, StringIO.new(stdout), StringIO.new(stderr), wait_thr)
  end
end

# SHASUMS256.txt as published on a Tuist release (several assets, one per line).
def shasums_content(zip_sha = ZIP_SHA256, zip_name: 'tuist.zip')
  [
    "#{'a' * 64}  ProjectDescription.framework.zip",
    "#{zip_sha}  #{zip_name}",
    "#{'b' * 64}  tuist.zip.sig"
  ].join("\n") + "\n"
end

# Popen3 handler that behaves like the real toolchain without touching it:
# `curl -o <file> <url>` writes the fixture for <file> into the current
# directory, every other command succeeds. A command matching `fail` exits
# non-zero with `fail_stderr`.
def fake_toolchain(shasums: shasums_content, zip_body: ZIP_BODY, fail: nil, fail_stderr: 'boom')
  lambda do |cmd|
    next ['', fail_stderr, false] if fail && cmd.match?(fail)

    if (m = cmd.match(/\Acurl .* -o (\S+) \S+\z/))
      File.write(m[1], m[1] == 'SHASUMS256.txt' ? shasums : zip_body)
    end
    ["#{cmd.split.first} ok\n", '', true]
  end
end

# Runs the block with $stdout and $stderr captured.
# Returns [stdout, stderr, SystemExit or nil].
def capture_io
  old_out = $stdout
  old_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  exit_error = nil
  begin
    yield
  rescue SystemExit => e
    exit_error = e
  end
  [$stdout.string, $stderr.string, exit_error]
ensure
  $stdout = old_out
  $stderr = old_err
end

# Ruby's Coverage resets a file's counters on every `load`, so a snapshot is
# taken before each load and summed into the final report.
COVERAGE_SNAPSHOTS = []

def snapshot_coverage
  return unless defined?(Coverage) && Coverage.running?

  data = Coverage.peek_result[MAIN_RB]
  COVERAGE_SNAPSHOTS << data if data
end

# Stubs the `tuist version` backtick call made at the top level of main.rb.
# Pass a String for its output, or an exception class to raise.
def stub_tuist_version(result)
  stub = allow(TOPLEVEL_BINDING.receiver).to receive(:`).with('tuist version 2>/dev/null')
  result.is_a?(Class) ? stub.and_raise(result) : stub.and_return(result)
end

# Runs main.rb's step body in-process with the given ENV, from `workdir`, with
# HOME pointing at `home`. Returns [stdout, stderr, SystemExit or nil] and the
# PATH / TUIST_STATS_OPT_OUT values the step left behind.
def run_step(env, workdir:, home:)
  result = nil
  with_clean_env do
    ENV['HOME'] = home
    env.each { |k, v| ENV[k] = v }
    old_program_name = $PROGRAM_NAME
    old_verbose = $VERBOSE
    $PROGRAM_NAME = MAIN_RB
    $VERBOSE = nil # silence "already initialized constant DEFAULT_TUIST_VERSION"
    snapshot_coverage
    begin
      Dir.chdir(workdir) do
        out, err, error = capture_io { load MAIN_RB }
        result = { out: out, err: err, error: error,
                   path: ENV['PATH'], opt_out: ENV['TUIST_STATS_OPT_OUT'] }
      end
    ensure
      $PROGRAM_NAME = old_program_name
      $VERBOSE = old_verbose
    end
  end
  result
end

# Runs main.rb in a subprocess with the given ENV. Every variable the step reads
# is unset first (a nil value unsets it in the child), so the ambient
# environment cannot leak in.
def run_main(env = {}, chdir: PROJECT_ROOT)
  clean_env = (STEP_ENV_KEYS + ['TUIST_STATS_OPT_OUT']).to_h { |k| [k, nil] }
  Open3.capture3(clean_env.merge(env), "ruby #{MAIN_RB}", chdir: chdir)
end

# Writes fake `tuist`, `curl` and `ditto` executables into bin_dir. All three
# append their arguments to $FAKE_TOOL_LOG and never reach the network or the
# real toolchain, so the subprocess tests run the real step in isolation.
#   FAKE_TUIST_VERSION=x       -> `tuist version` prints x (prints nothing when unset)
#   FAKE_TUIST_GENERATE_FAIL=1 -> `tuist generate` prints an error and exits 1
#   FAKE_CURL_FAIL=1           -> curl prints an error and exits 22
#   FAKE_SHASUMS / FAKE_ZIP    -> files curl "downloads" for SHASUMS256.txt / tuist.zip
def write_fake_tools(bin_dir)
  FileUtils.mkdir_p(bin_dir)
  {
    'tuist' => <<~SH,
      #!/bin/sh
      echo "tuist $*" >> "$FAKE_TOOL_LOG"
      case "$1" in
        version)
          [ -n "$FAKE_TUIST_VERSION" ] && echo "$FAKE_TUIST_VERSION"
          exit 0
          ;;
        generate)
          if [ "$FAKE_TUIST_GENERATE_FAIL" = "1" ]; then
            echo "tuist: error: Manifest not found" >&2
            exit 1
          fi
          echo "Project generated. TUIST_STATS_OPT_OUT=$TUIST_STATS_OPT_OUT"
          ;;
      esac
    SH
    'curl' => <<~SH,
      #!/bin/sh
      echo "curl $*" >> "$FAKE_TOOL_LOG"
      out=""; url=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o) out="$2"; shift 2 ;;
          --retry) shift 2 ;;
          -*) shift ;;
          *) url="$1"; shift ;;
        esac
      done
      if [ "$FAKE_CURL_FAIL" = "1" ]; then
        echo "curl: (22) The requested URL returned error: 404" >&2
        exit 22
      fi
      case "$url" in
        */SHASUMS256.txt) cp "$FAKE_SHASUMS" "$out" ;;
        */tuist.zip) cp "$FAKE_ZIP" "$out" ;;
      esac
    SH
    'ditto' => <<~SH
      #!/bin/sh
      echo "ditto $*" >> "$FAKE_TOOL_LOG"
    SH
  }.each do |name, body|
    path = File.join(bin_dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
  end
  bin_dir
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_TEST_VAR'] = '4.214.0'
      expect(env_has_key('_TEST_VAR')).to eq('4.214.0')
    end

    it 'keeps whitespace-only values as-is' do
      ENV['_TEST_VAR'] = '  '
      expect(env_has_key('_TEST_VAR')).to eq('  ')
    end
  end

  context 'negative path' do
    it 'returns nil when the key is missing' do
      ENV.delete('_TEST_VAR')
      expect(env_has_key('_TEST_VAR')).to be_nil
    end

    it 'returns nil when the value is an empty string' do
      ENV['_TEST_VAR'] = ''
      expect(env_has_key('_TEST_VAR')).to be_nil
    end

    it 'raises TypeError for a nil key' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#runCommand' do
  let(:commands) { [] }

  context 'positive path' do
    it 'passes the command string to Open3.popen3 unchanged' do
      stub_popen3(recorder: commands)
      capture_io { runCommand('tuist generate -p /work/App') }
      expect(commands).to eq(['tuist generate -p /work/App'])
    end

    it 'logs the command and streams stdout line by line' do
      stub_popen3 { ["Loading manifests\nProject generated.\n", '', true] }
      out, _err, error = capture_io { runCommand('tuist generate -p /work/App') }
      expect(error).to be_nil
      expect(out).to eq("@@[command] tuist generate -p /work/App\nLoading manifests\nProject generated.\n")
    end

    it 'prints only the command log when the command succeeds silently' do
      stub_popen3
      out, _err, _error = capture_io { runCommand('true') }
      expect(out).to eq("@@[command] true\n")
    end

    it 'does not raise when a successful command writes to stderr' do
      stub_popen3 { ['ok', 'warning: something', true] }
      expect { capture_io { runCommand('tuist generate -p .') } }.not_to raise_error
    end
  end

  context 'negative path' do
    it 'raises RuntimeError with stderr when the command fails' do
      stub_popen3 { ['', 'curl: (22) The requested URL returned error: 404', false] }
      expect { capture_io { runCommand("#{CURL} -o tuist.zip https://x/tuist.zip") } }
        .to raise_error(RuntimeError, 'curl: (22) The requested URL returned error: 404')
    end

    it 'still prints stdout produced before the failure' do
      stub_popen3 { ["partial output\n", 'boom', false] }
      old_out = $stdout
      $stdout = StringIO.new
      begin
        expect { runCommand('tuist generate -p .') }.to raise_error(RuntimeError, 'boom')
        out = $stdout.string
      ensure
        $stdout = old_out
      end
      expect(out).to eq("@@[command] tuist generate -p .\npartial output\n")
    end

    it 'raises RuntimeError with an empty message when a failing command has empty stderr' do
      stub_popen3 { ['', '', false] }
      expect { capture_io { runCommand('false') } }.to raise_error(RuntimeError, '')
    end

    it 'propagates errors raised by Open3.popen3 (e.g. executable not found)' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'tuist')
      expect { capture_io { runCommand('tuist generate -p .') } }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'step execution' do
  let(:tmpdir)      { Dir.mktmpdir('tuist_step') }
  let(:workdir)     { File.join(tmpdir, 'work').tap { |d| FileUtils.mkdir_p(d) } }
  let(:home)        { File.join(tmpdir, 'home').tap { |d| FileUtils.mkdir_p(d) } }
  let(:env_file)    { File.join(tmpdir, 'env_file') }
  let(:commands)    { [] }
  let(:project_dir) { '/work/App' }
  let(:base_env)    { { 'AC_TUIST_PATH' => project_dir } }

  after { FileUtils.rm_rf(tmpdir) }

  def step(env = base_env)
    run_step(env, workdir: workdir, home: home)
  end

  def install_dir(version = DEFAULT_TUIST_VERSION)
    File.join(home, 'tuist', version)
  end

  def download_commands(version = DEFAULT_TUIST_VERSION, base: DEFAULT_BASE_URL)
    [
      "#{CURL} -o SHASUMS256.txt #{base}/#{version}/SHASUMS256.txt",
      "#{CURL} -o tuist.zip #{base}/#{version}/tuist.zip",
      "ditto -x -k tuist.zip #{install_dir(version)}"
    ]
  end

  context 'positive path – requested version already on PATH' do
    before do
      stub_tuist_version("#{DEFAULT_TUIST_VERSION}\n")
      stub_popen3(recorder: commands, &fake_toolchain)
    end

    it 'skips the download and only runs tuist generate' do
      result = step
      expect(result[:error]).to be_nil
      expect(result[:out]).to include("Tuist #{DEFAULT_TUIST_VERSION} is already installed, skipping download.")
      expect(commands).to eq(["tuist generate -p #{project_dir}"])
    end

    it 'leaves PATH unchanged and creates no install directory' do
      original_path = ENV['PATH']
      result = step
      expect(result[:path]).to eq(original_path)
      expect(Dir.exist?(File.join(home, 'tuist'))).to be(false)
    end

    it 'sets TUIST_STATS_OPT_OUT=1' do
      expect(step[:opt_out]).to eq('1')
    end

    it 'uses the last line of a multi-line `tuist version` output' do
      stub_tuist_version("Warning: a newer version is available\n#{DEFAULT_TUIST_VERSION}\n")
      expect(step[:out]).to include('already installed, skipping download')
      expect(commands).to eq(["tuist generate -p #{project_dir}"])
    end

    it 'compares against AC_TUIST_VERSION when it is set' do
      stub_tuist_version("4.50.2\n")
      step(base_env.merge('AC_TUIST_VERSION' => '4.50.2'))
      expect(commands).to eq(["tuist generate -p #{project_dir}"])
    end
  end

  context 'positive path – download and install' do
    before do
      stub_tuist_version("4.0.0\n")
      stub_popen3(recorder: commands, &fake_toolchain)
    end

    it 'downloads SHASUMS256.txt and tuist.zip of the default version, extracts and generates' do
      result = step
      expect(result[:error]).to be_nil
      expect(commands).to eq(download_commands + ["tuist generate -p #{project_dir}"])
    end

    it 'falls back to the default version when AC_TUIST_VERSION is empty' do
      step(base_env.merge('AC_TUIST_VERSION' => ''))
      expect(commands.first).to eq("#{CURL} -o SHASUMS256.txt #{DEFAULT_BASE_URL}/#{DEFAULT_TUIST_VERSION}/SHASUMS256.txt")
    end

    it 'downloads the version given in AC_TUIST_VERSION' do
      step(base_env.merge('AC_TUIST_VERSION' => '4.50.2'))
      expect(commands).to eq(download_commands('4.50.2') + ["tuist generate -p #{project_dir}"])
    end

    it 'uses AC_TUIST_BASE_URL and strips a trailing slash' do
      step(base_env.merge('AC_TUIST_BASE_URL' => 'https://mirror.example.test/tuist/'))
      expect(commands.first(2)).to eq(download_commands(base: 'https://mirror.example.test/tuist').first(2))
    end

    it 'falls back to the GitHub releases URL when AC_TUIST_BASE_URL is empty' do
      step(base_env.merge('AC_TUIST_BASE_URL' => ''))
      expect(commands.first).to start_with("#{CURL} -o SHASUMS256.txt #{DEFAULT_BASE_URL}/")
    end

    it 'prints the download URL and the verified checksum' do
      out = step[:out]
      expect(out).to include("Downloading Tuist #{DEFAULT_TUIST_VERSION} from #{DEFAULT_BASE_URL}/#{DEFAULT_TUIST_VERSION}/tuist.zip")
      expect(out).to include("Checksum verified: #{ZIP_SHA256}")
    end

    it 'accepts a "./tuist.zip" entry in SHASUMS256.txt' do
      stub_popen3(recorder: commands, &fake_toolchain(shasums: shasums_content(zip_name: './tuist.zip')))
      result = step
      expect(result[:error]).to be_nil
      expect(result[:out]).to include("Checksum verified: #{ZIP_SHA256}")
    end

    it 'creates the install directory under $HOME/tuist/<version>' do
      step
      expect(Dir.exist?(install_dir)).to be(true)
    end

    it 'removes tuist.zip and SHASUMS256.txt from the working directory' do
      step
      expect(Dir.children(workdir)).to be_empty
    end

    it 'prepends the install directory to PATH' do
      original_path = ENV['PATH']
      expect(step[:path]).to eq("#{install_dir}:#{original_path}")
    end

    it 'downloads when `tuist version` prints nothing (tuist not installed)' do
      stub_tuist_version('')
      step
      expect(commands).to eq(download_commands + ["tuist generate -p #{project_dir}"])
    end

    it 'downloads when running `tuist version` raises Errno::ENOENT' do
      stub_tuist_version(Errno::ENOENT)
      result = step
      expect(result[:error]).to be_nil
      expect(commands).to eq(download_commands + ["tuist generate -p #{project_dir}"])
    end
  end

  context 'positive path – version already extracted under $HOME/tuist' do
    before do
      stub_tuist_version("4.0.0\n")
      stub_popen3(recorder: commands, &fake_toolchain)
      FileUtils.mkdir_p(install_dir)
      File.write(File.join(install_dir, 'tuist'), '')
    end

    it 'skips the download but still prepends the install directory to PATH' do
      original_path = ENV['PATH']
      result = step
      expect(commands).to eq(["tuist generate -p #{project_dir}"])
      expect(result[:out]).not_to include('Downloading Tuist')
      expect(result[:path]).to eq("#{install_dir}:#{original_path}")
    end
  end

  context 'positive path – AC_ENV_FILE_PATH' do
    before do
      stub_tuist_version("4.0.0\n")
      stub_popen3(recorder: commands, &fake_toolchain)
    end

    it 'appends PATH and TUIST_STATS_OPT_OUT=1 to the env file' do
      File.write(env_file, "EXISTING=1\n")
      original_path = ENV['PATH']
      step(base_env.merge('AC_ENV_FILE_PATH' => env_file))
      expect(File.read(env_file))
        .to eq("EXISTING=1\nPATH=#{install_dir}:#{original_path}\nTUIST_STATS_OPT_OUT=1\n")
    end

    it 'creates the env file when it does not exist yet' do
      step(base_env.merge('AC_ENV_FILE_PATH' => env_file))
      expect(File.read(env_file)).to end_with("TUIST_STATS_OPT_OUT=1\n")
    end

    it 'writes nothing when AC_ENV_FILE_PATH is missing' do
      result = step
      expect(result[:error]).to be_nil
      expect(File.exist?(env_file)).to be(false)
    end

    it 'writes nothing when AC_ENV_FILE_PATH is empty' do
      result = step(base_env.merge('AC_ENV_FILE_PATH' => ''))
      expect(result[:error]).to be_nil
      expect(commands.last).to eq("tuist generate -p #{project_dir}")
    end
  end

  context 'negative path – AC_TUIST_PATH' do
    before do
      stub_tuist_version("4.0.0\n")
      stub_popen3(recorder: commands, &fake_toolchain)
    end

    it 'aborts with "Missing AC_TUIST_PATH" when missing, before running any command' do
      result = step({})
      expect(result[:error].status).to eq(1)
      expect(result[:err]).to eq("Missing AC_TUIST_PATH\n")
      expect(commands).to be_empty
      expect(TOPLEVEL_BINDING.receiver).not_to have_received(:`)
    end

    it 'aborts with "Missing AC_TUIST_PATH" when empty' do
      result = step('AC_TUIST_PATH' => '')
      expect(result[:error].status).to eq(1)
      expect(result[:err]).to eq("Missing AC_TUIST_PATH\n")
      expect(commands).to be_empty
    end

    it 'passes a path with spaces to tuist generate unquoted (current behaviour pinned)' do
      step('AC_TUIST_PATH' => '/work/My App')
      expect(commands.last).to eq('tuist generate -p /work/My App')
    end
  end

  context 'negative path – SHASUMS256.txt' do
    before { stub_tuist_version("4.0.0\n") }

    it 'aborts when tuist.zip is not listed, before downloading tuist.zip' do
      stub_popen3(recorder: commands, &fake_toolchain(shasums: "#{'a' * 64}  other.zip\n"))
      result = step
      expect(result[:error].status).to eq(1)
      expect(result[:err]).to eq("tuist.zip is not listed in SHASUMS256.txt of Tuist #{DEFAULT_TUIST_VERSION}\n")
      expect(commands).to eq([download_commands.first])
    end

    it 'aborts when SHASUMS256.txt is empty' do
      stub_popen3(recorder: commands, &fake_toolchain(shasums: ''))
      result = step
      expect(result[:error].status).to eq(1)
      expect(result[:err]).to include('tuist.zip is not listed in SHASUMS256.txt')
    end

    it 'does not match a different asset whose name only contains "tuist.zip"' do
      stub_popen3(recorder: commands, &fake_toolchain(shasums: "#{ZIP_SHA256}  tuist.zip.sig\n"))
      expect(step[:err]).to include('tuist.zip is not listed in SHASUMS256.txt')
    end

    it 'raises with the curl error when SHASUMS256.txt cannot be downloaded' do
      stub_popen3(recorder: commands,
                  &fake_toolchain(fail: /SHASUMS256\.txt\z/, fail_stderr: 'curl: (22) The requested URL returned error: 404'))
      expect { step }.to raise_error(RuntimeError, 'curl: (22) The requested URL returned error: 404')
      expect(commands.size).to eq(1)
    end
  end

  context 'negative path – tuist.zip' do
    before { stub_tuist_version("4.0.0\n") }

    it 'aborts on a checksum mismatch without extracting or generating' do
      stub_popen3(recorder: commands, &fake_toolchain(zip_body: 'tampered'))
      result = step
      expect(result[:error].status).to eq(1)
      expect(result[:err])
        .to eq("Checksum mismatch for tuist.zip: expected #{ZIP_SHA256}, got #{Digest::SHA256.hexdigest('tampered')}\n")
      expect(commands).to eq(download_commands.first(2))
      expect(Dir.exist?(install_dir)).to be(false)
    end

    it 'leaves the downloaded files behind on a checksum mismatch (current behaviour pinned)' do
      stub_popen3(recorder: commands, &fake_toolchain(zip_body: 'tampered'))
      step
      expect(Dir.children(workdir)).to contain_exactly('SHASUMS256.txt', 'tuist.zip')
    end

    it 'raises with the curl error when tuist.zip cannot be downloaded' do
      stub_popen3(recorder: commands, &fake_toolchain(fail: /tuist\.zip\z/, fail_stderr: 'curl: (6) Could not resolve host'))
      expect { step }.to raise_error(RuntimeError, 'curl: (6) Could not resolve host')
      expect(commands).to eq(download_commands.first(2))
    end

    it 'raises with the ditto error when extraction fails' do
      stub_popen3(recorder: commands, &fake_toolchain(fail: /\Aditto /, fail_stderr: 'ditto: Couldn\'t read PKZip signature'))
      expect { step }.to raise_error(RuntimeError, "ditto: Couldn't read PKZip signature")
      expect(commands).to eq(download_commands)
    end
  end

  context 'negative path – tuist generate fails' do
    before do
      stub_tuist_version("#{DEFAULT_TUIST_VERSION}\n")
      stub_popen3(recorder: commands,
                  &fake_toolchain(fail: /\Atuist generate/, fail_stderr: 'tuist: error: Manifest not found'))
    end

    it 'raises with the tuist error' do
      expect { step }.to raise_error(RuntimeError, 'tuist: error: Manifest not found')
      expect(commands).to eq(["tuist generate -p #{project_dir}"])
    end

    it 'has already written the env file before generating' do
      expect { step(base_env.merge('AC_ENV_FILE_PATH' => env_file)) }.to raise_error(RuntimeError)
      expect(File.read(env_file)).to include("TUIST_STATS_OPT_OUT=1\n")
    end
  end

  context 'negative path – AC_ENV_FILE_PATH not writable' do
    before do
      stub_tuist_version("#{DEFAULT_TUIST_VERSION}\n")
      stub_popen3(recorder: commands, &fake_toolchain)
    end

    it 'raises Errno::ENOENT when its directory does not exist, before tuist generate' do
      missing = File.join(tmpdir, 'missing_dir', 'env_file')
      expect { step(base_env.merge('AC_ENV_FILE_PATH' => missing)) }.to raise_error(Errno::ENOENT)
      expect(commands).to be_empty
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  let(:tmpdir)   { Dir.mktmpdir('tuist_env') }
  let(:bin_dir)  { write_fake_tools(File.join(tmpdir, 'bin')) }
  let(:workdir)  { File.join(tmpdir, 'work').tap { |d| FileUtils.mkdir_p(d) } }
  let(:home)     { File.join(tmpdir, 'home').tap { |d| FileUtils.mkdir_p(d) } }
  let(:tool_log) { File.join(tmpdir, 'tool.log') }
  let(:env_file) { File.join(tmpdir, 'env_file') }
  let(:fixtures) do
    zip = File.join(tmpdir, 'fixture.zip')
    sums = File.join(tmpdir, 'fixture_shasums.txt')
    File.write(zip, ZIP_BODY)
    File.write(sums, shasums_content)
    { zip: zip, shasums: sums }
  end
  let(:install_dir) { File.join(home, 'tuist', DEFAULT_TUIST_VERSION) }
  let(:base_env) do
    {
      'PATH'          => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}",
      'HOME'          => home,
      'FAKE_TOOL_LOG' => tool_log,
      'FAKE_ZIP'      => fixtures[:zip],
      'FAKE_SHASUMS'  => fixtures[:shasums],
      'AC_TUIST_PATH' => '/work/App'
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def tool_calls
    File.exist?(tool_log) ? File.read(tool_log).lines.map(&:chomp) : []
  end

  def main(env)
    run_main(env, chdir: workdir)
  end

  shared_examples 'aborts with message' do |env_override, expected_pattern|
    it "exits non-zero and stderr matches /#{expected_pattern.source}/" do
      env = instance_exec(&env_override)
      _out, err, status = main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(expected_pattern)
    end
  end

  context 'required variable: AC_TUIST_PATH' do
    context 'when missing' do
      include_examples 'aborts with message',
                       -> { base_env.reject { |k, _| k == 'AC_TUIST_PATH' } },
                       /Missing AC_TUIST_PATH/
    end

    context 'when an empty string' do
      include_examples 'aborts with message', -> { base_env.merge('AC_TUIST_PATH' => '') }, /Missing AC_TUIST_PATH/
    end

    it 'runs no tool when it is missing' do
      main(base_env.reject { |k, _| k == 'AC_TUIST_PATH' })
      expect(tool_calls).to be_empty
    end
  end

  context 'toolchain failures' do
    it 'exits non-zero with the curl error and does not install' do
      _out, err, status = main(base_env.merge('FAKE_CURL_FAIL' => '1'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('curl: (22) The requested URL returned error: 404')
      expect(tool_calls.grep(/\Aditto|\Atuist generate/)).to be_empty
    end

    it 'exits non-zero on a checksum mismatch' do
      File.write(fixtures[:zip], 'tampered')
      _out, err, status = main(base_env)
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Checksum mismatch for tuist.zip')
      expect(tool_calls.grep(/\Aditto/)).to be_empty
    end

    it 'exits non-zero with the tuist generate error' do
      _out, err, status = main(base_env.merge('FAKE_TUIST_VERSION' => DEFAULT_TUIST_VERSION,
                                              'FAKE_TUIST_GENERATE_FAIL' => '1'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('tuist: error: Manifest not found')
    end
  end

  context 'all variables set' do
    it 'skips the download when the requested version is installed and exits 0' do
      out, err, status = main(base_env.merge('FAKE_TUIST_VERSION' => DEFAULT_TUIST_VERSION))
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      expect(out).to include('is already installed, skipping download.')
      expect(tool_calls).to eq(['tuist version', 'tuist generate -p /work/App'])
    end

    it 'downloads, verifies, extracts, writes the env file and generates with stats opted out' do
      out, err, status = main(base_env.merge('AC_TUIST_VERSION' => DEFAULT_TUIST_VERSION,
                                             'AC_TUIST_BASE_URL' => 'https://mirror.example.test/tuist/',
                                             'AC_ENV_FILE_PATH' => env_file))
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      url = "https://mirror.example.test/tuist/#{DEFAULT_TUIST_VERSION}"
      expect(tool_calls).to eq([
        'tuist version',
        "curl -fsSL --retry 3 -o SHASUMS256.txt #{url}/SHASUMS256.txt",
        "curl -fsSL --retry 3 -o tuist.zip #{url}/tuist.zip",
        "ditto -x -k tuist.zip #{install_dir}",
        'tuist generate -p /work/App'
      ])
      expect(out).to include("Checksum verified: #{ZIP_SHA256}")
      expect(out).to include('Project generated. TUIST_STATS_OPT_OUT=1')
      expect(File.read(env_file)).to eq("PATH=#{install_dir}:#{base_env['PATH']}\nTUIST_STATS_OPT_OUT=1\n")
      expect(Dir.children(workdir)).to be_empty
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'loading main.rb' do
  it 'does not execute the step when required from another script' do
    out, err, status = Open3.capture3(STEP_ENV_KEYS.to_h { |k| [k, nil] },
                                      "ruby -e 'require %q(#{MAIN_RB}); puts :loaded'")
    expect(status.exitstatus).to eq(0)
    expect(err).to eq('')
    expect(out.strip).to eq('loaded')
  end

  it 'defines env_has_key, runCommand and DEFAULT_TUIST_VERSION' do
    expect(respond_to?(:env_has_key, true)).to be(true)
    expect(respond_to?(:runCommand, true)).to be(true)
    expect(DEFAULT_TUIST_VERSION).to eq('4.214.0')
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = COVERAGE_SNAPSHOTS.reduce(result[main_path]) do |acc, snap|
    acc.zip(snap).map { |a, b| a.nil? ? nil : a + b.to_i }
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end

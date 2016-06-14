require 'tempfile'

class Profile
  def initialize prof, addr_to_func
    @prof         = prof
    @addr_to_func = addr_to_func
  end

  def sample_count
    @prof.values.inject :+
  end

  def addresses
    @prof.keys.flatten.uniq
  end

  def flat
    counts = Hash.new 0

    @prof.each_pair do |stack, ticks|
      name = atofun(stack.first)
      counts[name] += ticks
    end

    counts
  end

  def cumulative
    counts = Hash.new 0

    @prof.each_pair do |stack, ticks|
      stack.each do |addr|
        counts[atofun(addr)] += ticks
      end
    end

    counts
  end

  private


  def atofun address
    @addr_to_func[address] || format_pointer(address)
  end

  def format_pointer ptr
    sprintf("%016x", ptr)
  end
end

class AddrToFunction
  def self.load binary
    lastfunc = nil
    addr_to_func = {}
    vm_core = []
    IO.popen "otool -tV #{binary}" do |f|
      f.each_line do |line|
        l = line.chomp.split("\t")
        if l.length == 1
          lastfunc = l.first.sub(/:$/, '')
        else
          if lastfunc
            addr = l.first.to_i 16
            addr_to_func[addr] = lastfunc
          end
        end
      end
    end
    addr_to_func
  end
end

class VMCoreExec
  def self.map src_root, bin_file, addr_to_func
    core_addrs = addr_to_func.find_all { |k,v| v == '_vm_exec_core' }
    resolved_insns = resolve_embedded core_addrs, src_root, bin_file
    exec_core_insns = {}
    core_addrs.zip(resolved_insns) do |(addr, orig), insn|
      exec_core_insns[addr] = insn || orig
    end
    exec_core_insns
  end

  # We want to blame any embedded code on the instruction they were inside.
  # IOW, we want any functions inlined inside an instruction to weigh down
  # that particular instruction
  def self.resolve_embedded addr_to_func, src_root, bin_file
    addrs = addr_to_func.map(&:first).map { |addr| sprintf("%016x", addr) }

    tempfile = Tempfile.new 'addresses'
    tempfile.write addrs.join ' '
    tempfile.close

    locs = IO.popen("atos -o #{bin_file} -f #{tempfile.path}") do |f|
      f.readlines
    end

    last_known = nil
    adjusted_locations = locs.map do |loc|
      if loc =~ /vm.inc|insns.def/
        last_known = loc
      else
        if last_known
          loc = last_known
        end
      end
      loc
    end

    insns  = INSNS.build File.join(src_root, 'insns.def')
    vm_inc = VMINC.build File.join(src_root, 'vm.inc')

    adjusted_locations.map do |loc|
      file, line = loc[/\([^\)]*\)$/].gsub(/[\(\)]/, '').split(':')
      case file
      when /vm.inc/
        vm_inc.func_for line.to_i
      when /insns.def/
        insns.func_for line.to_i
      else
        nil
      end
    end
  ensure
    tempfile.unlink
  end

  class RubyFile < Struct.new(:lines)
    def self.build filename
      new File.readlines filename
    end
  end

  class INSNS < RubyFile
    def func_for line_number
      line_number = line_number - 1
      while line_number > 0
        if lines[line_number] =~ /DEFINE_INSN/
          return lines[line_number + 1].chomp
        end
        line_number -= 1
      end
    end
  end

  class VMINC < RubyFile
    def func_for line_number
      line_number = line_number - 1
      while line_number > 0
        if lines[line_number] =~ /INSN_ENTRY\(([^\)]*)\)/
          return $1
        end
        line_number -= 1
      end
    end
  end
end

PROFILE     = ARGV[0]
RUBY_BINARY = ARGV[1]
RUBY_SOURCE = ARGV[2]

File.open(PROFILE, 'rb') do |f|
  header = f.read(8).bytes
  if header.all?(&:zero?)
    puts "sixty four"
  else
    raise "32 bit not supported"
  end

  left, right = f.read(8).unpack("ll")
  if left == 3
    # little endian
    puts "little endian"
  else
    # big endian
    raise "error" unless right == 3
    raise "64 bit big endian not supported"
  end

  version, period, _ = f.read(8 * 3).unpack("Q<3")
  raise "wrong version" unless version == 0

  profile = Hash.new 0
  loop do
    ticks, pcs = f.read(8 * 2).unpack("Q<2")
    break if ticks == 0 # done parsing

    profile[f.read(8 * pcs).unpack("Q<#{pcs}")] += ticks
  end

  addr2func = AddrToFunction.load(RUBY_BINARY)

  if RUBY_SOURCE
    core_exec = VMCoreExec.map RUBY_SOURCE, RUBY_BINARY, addr2func
    addr2func.merge! core_exec
  end

  profile = Profile.new profile, addr2func
  #puts profile.sample_count
  p profile.flat
end

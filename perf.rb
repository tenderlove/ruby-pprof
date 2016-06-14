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

  def text
    "Total: #{sample_count} samples\n" +
      build_text(sample_count.to_f, flat, cumulative).join
  end

  private

  def build_text total, flat, cumulative
    keys = flat.keys.sort_by { |k| flat[k] }.reverse + (cumulative.keys - flat.keys).sort.reverse
    sum = 0
    keys.map do |key|
      flat_weight       = flat[key]
      cumulative_weight = cumulative[key]

      sum += flat_weight
      sprintf "%8d %6.1f%% %6.1f%% %8d %6.1f%% %s\n",
             flat_weight,
             (flat_weight / total) * 100,
             (sum / total) * 100,
             cumulative_weight,
             (cumulative_weight / total) * 100,
             key
    end
  end

  def atofun address
    @addr_to_func[address] || format_pointer(address)
  end

  def format_pointer ptr
    sprintf("0x%016x", ptr)
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
          return "vm: " + lines[line_number + 1].chomp
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
          return "vm: " + $1
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
  unless header.all?(&:zero?) # 64 bit profile
    raise "32 bit not supported"
  end

  left, right = f.read(8).unpack("ll")
  unless left == 3 # little endian
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
  puts profile.text
end

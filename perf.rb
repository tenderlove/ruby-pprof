require 'tempfile'

class Profile
  def initialize prof, addr_to_func
    @prof         = prof
    @addr_to_func = addr_to_func
    resolve_vm_exec_core prof, addr_to_func
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
      if name == '_vm_exec_core'
        p :next => atofun(stack[2])
      end
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

  def resolve_vm_exec_core prof, addr_to_func
    core_addrs = addr_to_func.find_all { |k,v| v == '_vm_exec_core' }
    atos(core_addrs).each do |addr, func|
      addr_to_func[addr] = func
    end
  end

  def atos addr_to_func
    addrs = addr_to_func.map(&:first).map { |addr| sprintf("%016x", addr) }

    tempfile = Tempfile.new 'addresses'
    tempfile.write addrs.join ' '
    tempfile.close

    locs = IO.popen("atos -o ./ruby -f #{tempfile.path}") do |f|
      f.readlines.to_a.map { |l| l.chomp[/\([^\)]*\)$/].gsub(/[\(\)]/, '').split(':') }
    end

    addr_to_func.zip(locs).map do |(addr, default), (file, line)|
      func = if reader = RubyFiles.for(file)
               reader.func_for line.to_i
             else
               p [addr.to_s(16), file, line]
               default
             end
      [addr, func]
    end
  ensure
    tempfile.unlink
  end

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

class RubyFiles
  FILES = {}

  def self.load file
    new File.readlines file
  end

  def initialize lines
    @lines = lines
  end

  class INSNS < RubyFiles
    def func_for line_number
      while line_number > 0
        if @lines[line_number] =~ /DEFINE_INSN/
          return @lines[line_number + 1].chomp
        end
        line_number -= 1
      end
    end
  end

  class VMINC < RubyFiles
    def func_for line_number
      while line_number > 0
        if @lines[line_number] =~ /INSN_ENTRY\(([^\)]*)\)/
          return $1
        end
        line_number -= 1
      end
    end
  end

  def self.for file
    FILES[file]
  end

  FILES['insns.def'] = INSNS.load 'insns.def'
  FILES['vm.inc'] = VMINC.load 'vm.inc'
end

File.open(ARGV[0], 'rb') do |f|
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
  profile = Profile.new profile, AddrToFunction.load("./ruby")
  #puts profile.sample_count
  p profile.flat
end

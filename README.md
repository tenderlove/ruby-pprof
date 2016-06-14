# Ruby pprof

This is a hack I wrote for parsing perftools output files. It *only* works on OS X.
It could probably have support for Linux, but I'm doing my profiling on OS X, so
that's why I target OS X.

## How to use?

You need to compile your Ruby in a special way to use this.  OS X uses address
randomization, and if that isn't disabled then addresses won't map back to
locations.

Here is how I ran `configure` for my Ruby:

```
$ ./configure --prefix=/Users/aaron/.rbenv/versions/ruby-trunk \
              --disable-install-rdoc \
              --disable-tk \
              --with-readline-dir=/usr/local/opt/readline \
              CC=clang \
              CFLAGS='-O3 -g -I/usr/local/Cellar/gperftools/2.5/include' \
              LDFLAGS='-Wl,-no_pie -L/usr/local/Cellar/gperftools/2.5/lib' \
              LIBS=-lprofiler
```

The `-Wl,-no_pie` part disables address randomization.  The other flags ensure
we compile and link with gperftools (which I installed via Homebrew).

To use the actual script, just run your benchmark program with the `CPUPROFILE`
environment variable set like this:

```
[aaron@TC ruby (trunk)]$ cat test.rb
def fib n
  if n < 3
    1
  else
    fib(n-1) + fib(n-2)
  end
end

fib(40)

[aaron@TC ruby (trunk)]$ CPUPROFILE=out.prof ruby test.rb
PROFILE: interrupts/evictions/bytes = 694/0/25320
[aaron@TC ruby (trunk)]$
```

You should end up with a profile file called `out.prof`.  Run the analysis script
like this:

```
[aaron@TC ruby-pprof (master)]$ ruby perf.rb out.prof `rbenv which ruby`
Total: 694 samples
     634   91.4%   91.4%      699  100.7% _vm_exec_core
      57    8.2%   99.6%       57    8.2% _vm_call_iseq_setup_normal_0start_1params_2locals
       2    0.3%   99.9%        2    0.3% _new_insn_body
       1    0.1%  100.0%       14    2.0% _iseq_compile_each
       0    0.0%  100.0%      699  100.7% _vm_exec
       0    0.0%  100.0%        8    1.2% _vm_call_cfunc
       0    0.0%  100.0%      691   99.6% _ruby_run_node
       0    0.0%  100.0%        3    0.4% _ruby_process_options
       0    0.0%  100.0%        3    0.4% _ruby_options
       0    0.0%  100.0%        3    0.4% _ruby_init_prelude
       0    0.0%  100.0%      691   99.6% _ruby_exec_node
       0    0.0%  100.0%      691   99.6% _ruby_exec_internal
       0    0.0%  100.0%        2    0.3% _rb_yield
       0    0.0%  100.0%        5    0.7% _rb_require_safe
       0    0.0%  100.0%        5    0.7% _rb_require_internal
       0    0.0%  100.0%        5    0.7% _rb_load_internal0
       0    0.0%  100.0%        7    1.0% _rb_iseq_new_with_opt
       0    0.0%  100.0%        2    0.3% _rb_iseq_new_top
       0    0.0%  100.0%        1    0.1% _rb_iseq_compile_with_option
       0    0.0%  100.0%        7    1.0% _rb_iseq_compile_node
       0    0.0%  100.0%        1    0.1% _rb_f_eval
       0    0.0%  100.0%        2    0.3% _rb_ary_each
       0    0.0%  100.0%        3    0.4% _process_options
       0    0.0%  100.0%      694  100.0% _main
       0    0.0%  100.0%        1    0.1% _eval_string_with_cref
```

The above profile shows that we spend most of our time in `vm_exec_core`.  That
function is the virtual machine's run loop.  YARV uses a technique called
"direct threading" which essentially inlines all byte code handling to one
function.   What this means is that when using a C level profiler, it looks like
we spend all our time in one function.

If you point the script at the source directory where you built Ruby, it will
break apart `vm_exec_core` so you can see information about each byte code:

```
[aaron@TC ruby-pprof (master)]$ ruby perf.rb out.prof `rbenv which ruby` ~/git/ruby
Total: 694 samples
     180   25.9%   25.9%      180   25.9% vm: trace
     135   19.5%   45.4%      198   28.5% vm: opt_send_without_block
      70   10.1%   55.5%       70   10.1% vm: leave
      57    8.2%   63.7%       57    8.2% vm: opt_minus
      57    8.2%   71.9%       57    8.2% _vm_call_iseq_setup_normal_0start_1params_2locals
      43    6.2%   78.1%       43    6.2% vm: opt_lt
      33    4.8%   82.9%       33    4.8% vm: opt_plus
      28    4.0%   86.9%       28    4.0% vm: putobject
      25    3.6%   90.5%       25    3.6% vm: getlocal_OP__WC__0
      15    2.2%   92.7%       15    2.2% vm: putobject_OP_INT2FIX_O_1_C_
      13    1.9%   94.5%       13    1.9% vm: putself
      12    1.7%   96.3%       12    1.7% vm: getlocal
      10    1.4%   97.7%       10    1.4% vm: branchunless
       9    1.3%   99.0%        9    1.3% vm: opt_case_dispatch
       4    0.6%   99.6%        4    0.6% vm: jump
       2    0.3%   99.9%        2    0.3% _new_insn_body
       1    0.1%  100.0%       14    2.0% _iseq_compile_each
       0    0.0%  100.0%        2    0.3% vm: send
       0    0.0%  100.0%      699  100.7% _vm_exec
       0    0.0%  100.0%        8    1.2% _vm_call_cfunc
       0    0.0%  100.0%      691   99.6% _ruby_run_node
       0    0.0%  100.0%        3    0.4% _ruby_process_options
       0    0.0%  100.0%        3    0.4% _ruby_options
       0    0.0%  100.0%        3    0.4% _ruby_init_prelude
       0    0.0%  100.0%      691   99.6% _ruby_exec_node
       0    0.0%  100.0%      691   99.6% _ruby_exec_internal
       0    0.0%  100.0%        2    0.3% _rb_yield
       0    0.0%  100.0%        5    0.7% _rb_require_safe
       0    0.0%  100.0%        5    0.7% _rb_require_internal
       0    0.0%  100.0%        5    0.7% _rb_load_internal0
       0    0.0%  100.0%        7    1.0% _rb_iseq_new_with_opt
       0    0.0%  100.0%        2    0.3% _rb_iseq_new_top
       0    0.0%  100.0%        1    0.1% _rb_iseq_compile_with_option
       0    0.0%  100.0%        7    1.0% _rb_iseq_compile_node
       0    0.0%  100.0%        1    0.1% _rb_f_eval
       0    0.0%  100.0%        2    0.3% _rb_ary_each
       0    0.0%  100.0%        3    0.4% _process_options
       0    0.0%  100.0%      694  100.0% _main
       0    0.0%  100.0%        1    0.1% _eval_string_with_cref
```

**IT IS EXTREMELY IMPORTANT** that the Ruby you used when running the benchmark
program was built from the source directory where you point this script.
Otherwise, it will map instructions incorrectly and the output will be wrong and
misleading.

I based my hack off [this post by Naruse](http://naruse.hateblo.jp/entry/2016/05/31/130315).

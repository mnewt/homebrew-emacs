class Gcc < Formula
  desc "GNU compiler collection"
  homepage "https://gcc.gnu.org/"
  url "https://ftp.gnu.org/gnu/gcc/gcc-10.2.0/gcc-10.2.0.tar.xz"
  mirror "https://ftpmirror.gnu.org/gcc/gcc-10.2.0/gcc-10.2.0.tar.xz"
  sha256 "b8dd4368bb9c7f0b98188317ee0254dd8cc99d1e3a18d0ff146c855fe16c1d8c"
  license "GPL-3.0"
  head "https://gcc.gnu.org/git/gcc.git"

  # The bottles are built on systems with the CLT installed, and do not work
  # out of the box on Xcode-only systems due to an incorrect sysroot.
  pour_bottle? do
    reason "The bottle needs the Xcode CLT to be installed."
    satisfy { MacOS::CLT.installed? }
  end

  depends_on "gmp"
  depends_on "isl"
  depends_on "libmpc"
  depends_on "mpfr"

  uses_from_macos "zlib"

  # GCC bootstraps itself, so it is OK to have an incompatible C++ stdlib
  cxxstdlib_check :skip

  def version_suffix
    if build.head?
      "HEAD"
    else
      version.to_s.slice(/\d+/)
    end
  end

  def install
    # GCC will suffer build errors if forced to use a particular linker.
    ENV.delete "LD"

    # We avoiding building:
    #  - Ada, which requires a pre-existing GCC Ada compiler to bootstrap
    #  - Go, currently not supported on macOS
    #  - BRIG
    languages = %w[c c++ objc obj-c++ fortran jit]

    osmajor = `uname -r`.split(".").first
    pkgversion = "Homebrew GCC #{pkg_version} #{build.used_options * " "}".strip

    args = %W[
      --build=x86_64-apple-darwin#{osmajor}
      --prefix=#{prefix}
      --libdir=#{lib}/gcc/#{version_suffix}
      --disable-nls
      --enable-checking=release
      --enable-languages=#{languages.join(",")}
      --program-suffix=-#{version_suffix}
      --with-gmp=#{Formula["gmp"].opt_prefix}
      --with-mpfr=#{Formula["mpfr"].opt_prefix}
      --with-mpc=#{Formula["libmpc"].opt_prefix}
      --with-isl=#{Formula["isl"].opt_prefix}
      --with-system-zlib
      --with-pkgversion=#{pkgversion}
      --with-bugurl=https://github.com/Homebrew/homebrew-core/issues
      --enable-host-shared
    ]

    # Xcode 10 dropped 32-bit support
    args << "--disable-multilib" if DevelopmentTools.clang_build_version >= 1000

    # System headers may not be in /usr/include
    sdk = MacOS.sdk_path_if_needed
    if sdk
      args << "--with-native-system-header-dir=/usr/include"
      args << "--with-sysroot=#{sdk}"
    end

    # Avoid reference to sed shim
    args << "SED=/usr/bin/sed"

    # Ensure correct install names when linking against libgcc_s;
    # see discussion in https://github.com/Homebrew/legacy-homebrew/pull/34303
    inreplace "libgcc/config/t-slibgcc-darwin", "@shlib_slibdir@", "#{HOMEBREW_PREFIX}/lib/gcc/#{version_suffix}"

    mkdir "build" do
      system "../configure", *args

      # Use -headerpad_max_install_names in the build,
      # otherwise updated load commands won't fit in the Mach-O header.
      # This is needed because `gcc` avoids the superenv shim.
      system "make", "BOOT_LDFLAGS=-Wl,-headerpad_max_install_names"
      system "make", "install"

      bin.install_symlink bin / "gfortran-#{version_suffix}" => "gfortran"
    end

    # Handle conflicts between GCC formulae and avoid interfering
    # with system compilers.
    # Rename man7.
    Dir.glob(man7 / "*.7") { |file| add_suffix file, version_suffix }
    # Even when we disable building info pages some are still installed.
    info.rmtree
  end

  def add_suffix(file, suffix)
    dir = File.dirname(file)
    ext = File.extname(file)
    base = File.basename(file, ext)
    File.rename file, "#{dir}/#{base}-#{suffix}#{ext}"
  end

  test do
    (testpath / "hello-c.c").write <<~EOS
                                     #include <stdio.h>
                                     int main()
                                     {
                                       puts("Hello, world!");
                                       return 0;
                                     }
                                   EOS
    system "#{bin}/gcc-#{version_suffix}", "-o", "hello-c", "hello-c.c"
    assert_equal "Hello, world!\n", `./hello-c`

    (testpath / "hello-cc.cc").write <<~EOS
                                       #include <iostream>
                                       int main()
                                       {
                                         std::cout << "Hello, world!" << std::endl;
                                         return 0;
                                       }
                                     EOS
    system "#{bin}/g++-#{version_suffix}", "-o", "hello-cc", "hello-cc.cc"
    assert_equal "Hello, world!\n", `./hello-cc`

    (testpath / "test.f90").write <<~EOS
                                    integer,parameter::m=10000
                                    real::a(m), b(m)
                                    real::fact=0.5

                                    do concurrent (i=1:m)
                                      a(i) = a(i) + fact*b(i)
                                    end do
                                    write(*,"(A)") "Done"
                                    end
                                  EOS
    system "#{bin}/gfortran", "-o", "test", "test.f90"
    assert_equal "Done\n", `./test`

    (testpath / "tut01-hello-world.c").write <<~EOS
                                               /* Smoketest example for libgccjit.so
   Copyright (C) 2014-2020 Free Software Foundation, Inc.

This file is part of GCC.

GCC is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option)
any later version.

GCC is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

#include <libgccjit.h>

#include <stdlib.h>
#include <stdio.h>

static void
create_code (gcc_jit_context *ctxt)
{
  /* Let's try to inject the equivalent of:
     void
     greet (const char *name)
     {
        printf ("hello %s\n", name);
     }
  */
  gcc_jit_type *void_type =
    gcc_jit_context_get_type (ctxt, GCC_JIT_TYPE_VOID);
  gcc_jit_type *const_char_ptr_type =
    gcc_jit_context_get_type (ctxt, GCC_JIT_TYPE_CONST_CHAR_PTR);
  gcc_jit_param *param_name =
    gcc_jit_context_new_param (ctxt, NULL, const_char_ptr_type, "name");
  gcc_jit_function *func =
    gcc_jit_context_new_function (ctxt, NULL,
                                  GCC_JIT_FUNCTION_EXPORTED,
                                  void_type,
                                  "greet",
                                  1, &param_name,
                                  0);

  gcc_jit_param *param_format =
    gcc_jit_context_new_param (ctxt, NULL, const_char_ptr_type, "format");
  gcc_jit_function *printf_func =
    gcc_jit_context_new_function (ctxt, NULL,
				  GCC_JIT_FUNCTION_IMPORTED,
				  gcc_jit_context_get_type (
				     ctxt, GCC_JIT_TYPE_INT),
				  "printf",
				  1, &param_format,
				  1);
  gcc_jit_rvalue *args[2];
  args[0] = gcc_jit_context_new_string_literal (ctxt, "hello %s\n");
  args[1] = gcc_jit_param_as_rvalue (param_name);

  gcc_jit_block *block = gcc_jit_function_new_block (func, NULL);

  gcc_jit_block_add_eval (
    block, NULL,
    gcc_jit_context_new_call (ctxt,
                              NULL,
                              printf_func,
                              2, args));
  gcc_jit_block_end_with_void_return (block, NULL);
}

int
main (int argc, char **argv)
{
  gcc_jit_context *ctxt;
  gcc_jit_result *result;

  /* Get a "context" object for working with the library.  */
  ctxt = gcc_jit_context_acquire ();
  if (!ctxt)
    {
      fprintf (stderr, "NULL ctxt");
      exit (1);
    }

  /* Set some options on the context.
     Let's see the code being generated, in assembler form.  */
  gcc_jit_context_set_bool_option (
    ctxt,
    GCC_JIT_BOOL_OPTION_DUMP_GENERATED_CODE,
    0);

  /* Populate the context.  */
  create_code (ctxt);

  /* Compile the code.  */
  result = gcc_jit_context_compile (ctxt);
  if (!result)
    {
      fprintf (stderr, "NULL result");
      exit (1);
    }

  /* Extract the generated code from "result".  */
  typedef void (*fn_type) (const char *);
  fn_type greet =
    (fn_type)gcc_jit_result_get_code (result, "greet");
  if (!greet)
    {
      fprintf (stderr, "NULL greet");
      exit (1);
    }

  /* Now call the generated function: */
  greet ("world");
  fflush (stdout);

  gcc_jit_context_release (ctxt);
  gcc_jit_result_release (result);
  return 0;
}
                                             EOS
    system "#{bin}/gcc", "-o", "tut01-hello-world", "tut01-hello-world.c", "-lgccjit"
    assert_equal "hello world\n", `./tut01-hello-world`
  end
end

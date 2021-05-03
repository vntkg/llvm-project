#!/bin/bash
# This is a convenience script to set up cmake in the EPI project.

function nice_message()
{
  local prefix="$1"
  local message="$2"

  if [ -z "$(which fmt)" ];
  then
    # Best effort if no fmt available in the PATH
    echo "$prefix: $message"
  else
    echo "$prefix: $message" | fmt -w80 --prefix="$prefix: "
  fi
}

function die()
{
  nice_message "ERROR" "$1"
  exit 1
}

function info()
{
  nice_message "INFO" "$1"
}

function warning()
{
  nice_message "WARNING" "$1"
}

function run()
{
  for i in "$@";
  do
    echo -n "'$i' "
  done
  echo

  "$@"
}

################################################################################
# Basic directory settings
################################################################################

BUILDDIR=$(readlink -f $(pwd))
SRCDIR=$(dirname $(readlink -f $0))

info "Using the current directory '${BUILDDIR}' as the build-dir"
info "Using '${SRCDIR}' as the source-dir"

if [ -z "${INSTALLDIR}" ];
then
  INSTALLDIR=$(readlink -f ${BUILDDIR}/../llvm-install)
  info "Using '${INSTALLDIR}' as the install-dir (you can override it setting INSTALLDIR)"
else
  info "Using '${INSTALLDIR}' as the install-dir"
fi
CMAKE_INVOCATION_EXTRA_FLAGS=("-DCMAKE_INSTALL_PREFIX=${INSTALLDIR}")

################################################################################
# Detection of build system
################################################################################

# We only support Makefiles or Ninja. Ninja is better as it is able of finer
# control

BUILD_SYSTEM="Unix Makefiles"
COMMAND_TO_BUILD="make -j$(nproc)"
NINJA_BIN=${NINJA_BIN:-$(which ninja)}

if [ -z "${NINJA_BIN}" ];
then
  info "Using Makefiles as build system because 'ninja' wasn't found in your PATH. You can override the location setting the NINJA_BIN environment variable"
elif [ ! -x "${NINJA_BIN}" ];
then
  info "Using Makefiles as build system because '${NINJA_BIN}' is not executable. You can override the location setting the NINJA_BIN environment variable"
else
  info "Using ninja in '${NINJA_BIN}'"
  BUILD_SYSTEM="Ninja"
  COMMAND_TO_BUILD="ninja"
  # Do not presume we can use 'ninja' as if it were in the path
  if [ -z "$(which ninja)" ];
  then
    COMMAND_TO_BUILD="${NINJA_BIN}"
  fi
fi

################################################################################
# Detection of compiler
################################################################################

# We only support clang or gcc. While the compilers are similar in speed, clang
# allows using LLD which is noticeably faster than GNU ld

if [ -z "${COMPILER}" ];
then
  info "Automatic detection of compiler. Override the detection setting the COMPILER environment variable to either 'gcc' or 'clang', in which case CC and CXX will be used by cmake instead"
  if [ -z "$(which clang)" ];
  then
    # Clang not found
    if [ -n "$(which gcc)" ];
    then
      COMPILER="gcc"
      info "Using GCC $(gcc -dumpversion)"
      info "gcc: $(which gcc)"
      if [ -n "$(which g++)" ];
      then
        info "g++: $(which g++)"
        # Sanity check
        if [ $(gcc -dumpversion) != $(g++ -dumpversion) ];
        then
          warning "gcc and g++ have different versions!"
        fi
        CC="$(which gcc)"
        CXX="$(which g++)"
      else
        error "g++ not found in the PATH but gcc was found. This usually means that your system is missing development packages"
      fi
    fi
  else
    CLANG_VERSION=$(clang --version | head -n1 | sed 's/^.*version\s\+\([0-9]\+\(\.[0-9]\+\)\+\).*$/\1/')
    COMPILER="clang"
    info "Using clang ${CLANG_VERSION}"
    info "clang: $(which clang)"
    if [ -n "$(which clang++)" ];
    then
      info "clang++: $(which clang++)"
      # Sanity check
      CLANGXX_VERSION=$(clang++ --version | head -n1 | sed 's/^.*version\s\+\([0-9]\+\(\.[0-9]\+\)\+\).*$/\1/')
      if [ "$CLANG_VERSION" != "$CLANGXX_VERSION" ];
      then
        warning "clang and clang++ have different versions!"
      fi
      CC="$(which clang)"
      CXX="$(which clang++)"
    else
      error "clang++ not found in the PATH but clang was found. You may have to review your installation"
    fi
  fi
elif [ "${COMPILER}" = gcc ];
then
  CC=${CC:-"$(which gcc)"}
  CXX=${CXX:-"$(which g++)"}
elif [ "${COMPILER}" = clang ];
then
  CC=${CC:-"$(which clang)"}
  CXX=${CXX:-"$(which clang++)"}
fi
CMAKE_INVOCATION_EXTRA_FLAGS+=("-DCMAKE_C_COMPILER=${CC}")
CMAKE_INVOCATION_EXTRA_FLAGS+=("-DCMAKE_CXX_COMPILER=${CXX}")

# Use C++ 14.
CMAKE_INVOCATION_EXTRA_FLAGS+=("-DCMAKE_CXX_STANDARD=14")


################################################################################
# Detection of the linker
################################################################################

# If using clang we try to use lld

LINKER=gnu-ld
if [ "$COMPILER" = "clang" ];
then
 if ( ${CC} -fuse-ld=lld -Wl,--version 2> /dev/null ) | grep -q "^LLD";
 then
   info "Using LLD"
   LINKER=lld
 else
   info "Using GNU ld because we didn't find lld"
 fi
else
  info "Using GNU ld because we are using gcc"
fi

if [ "$LINKER" = "lld" ];
then
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DLLVM_ENABLE_LLD=ON")
fi

if [ "$BUILD_SYSTEM" = "Ninja" ];
then
  NUM_LINK_JOBS=0
  if [ -n "$(which nproc)" ];
  then
    # Note these are heuristics based on experimentation
    if [ "$LINKER" = "lld" ];
    then
      NUM_LINK_JOBS=$(($(nproc)/4))
    else
      # GNU linker uses a lot of memory
      NUM_LINK_JOBS=$(($(nproc)/8))
    fi
  fi
  # At least 1
  NUM_LINK_JOBS=$((${NUM_LINK_JOBS} + 1))
  info "Limiting concurrent linking jobs to ${NUM_LINK_JOBS}"
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DLLVM_PARALLEL_LINK_JOBS=${NUM_LINK_JOBS}")
else
  warning "Makefiles do not allow limiting the concurrent linking jobs"
fi

################################################################################
# Detection of ccache
################################################################################

if [ -n "$(which ccache)" ];
then
  info "Using ccache: $(which ccache)"
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DLLVM_CCACHE_BUILD=ON")
  info "Setting LLVM_APPEND_VC_REV=OFF to improve ccache hit ratio"
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DLLVM_APPEND_VC_REV=OFF")
else
  info "Not using ccache as it was not found"
fi

################################################################################
# Flags for faster debugging
################################################################################

CMAKE_INVOCATION_EXTRA_FLAGS+=("-DCMAKE_CXX_FLAGS_DEBUG=-g -ggnu-pubnames")
if [ "$LINKER" = "lld" ];
then
  info "Make LLD generate '.gdb_index' section for faster debugging"
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DCMAKE_EXE_LINKER_FLAGS_DEBUG=-Wl,-gdb-index")
else
   info "GNU ld is used, '.gdb_index' sections for faster debugging won't be generated"
fi

################################################################################
# Prefer Python 3 (2.7 is deprecated and 3.x is often faster in lit)
################################################################################

PYTHON_BIN=${PYTHON_BIN:-$(which python3)}

if [ -n "${PYTHON_BIN}" ];
then
  info "Using python executable at '${PYTHON_BIN}'. Set PYTHON_BIN to override this."
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DPYTHON_EXECUTABLE=${PYTHON_BIN}")
else
  info "python3 not found in the PATH. Set PYTHON_BIN to override this."
fi

################################################################################
# cmake
################################################################################

if [ "$1" = "debug" ];
then
  CMAKE_INVOCATION_EXTRA_FLAGS+=("-DCMAKE_BUILD_TYPE=Debug")
  info "Build in Debug mode"
fi

info "Running cmake..."
run cmake -G "${BUILD_SYSTEM}" ${SRCDIR}/llvm \
   -DLLVM_ENABLE_PROJECTS="clang" \
   -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=RISCV \
   -DCMAKE_INSTALL_PREFIX=${INSTALLDIR} \
   -DLLVM_INSTALL_UTILS=ON \
   "${CMAKE_INVOCATION_EXTRA_FLAGS[@]}"

if [ $? = 0 ];
then
  echo ""
  echo "cmake finished successfully, you may want to tune the configuration in CMakeCache.txt or using a GUI tool like ccmake"
  echo ""
  echo "Now run '${COMMAND_TO_BUILD}' to build. Use '${COMMAND_TO_BUILD} install' to build and install."
fi

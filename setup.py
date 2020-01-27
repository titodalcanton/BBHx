# from future.utils import iteritems
import os
import shutil
from os.path import join as pjoin
from setuptools import setup
from distutils.extension import Extension
from Cython.Distutils import build_ext
import numpy
from distutils.dep_util import newer_pairwise, newer_group
from distutils import log
import subprocess
from distutils.spawn import spawn


def find_in_path(name, path):
    """Find a file in a search path"""

    # Adapted fom http://code.activestate.com/recipes/52224
    for dir in path.split(os.pathsep):
        binpath = pjoin(dir, name)
        if os.path.exists(binpath):
            return os.path.abspath(binpath)
    return None


def locate_cuda():
    """Locate the CUDA environment on the system

    Returns a dict with keys 'home', 'nvcc', 'include', and 'lib64'
    and values giving the absolute path to each directory.

    Starts by looking for the CUDAHOME env variable. If not found,
    everything is based on finding 'nvcc' in the PATH.
    """

    # First check if the CUDAHOME env variable is in use
    if "CUDAHOME" in os.environ:
        home = os.environ["CUDAHOME"]
        nvcc = pjoin(home, "bin", "nvcc")
    else:
        # Otherwise, search the PATH for NVCC
        nvcc = find_in_path("nvcc", os.environ["PATH"])
        if nvcc is None:
            raise EnvironmentError(
                "The nvcc binary could not be "
                "located in your $PATH. Either add it to your path, "
                "or set $CUDAHOME"
            )
        home = os.path.dirname(os.path.dirname(nvcc))

    cudaconfig = {
        "home": home,
        "nvcc": nvcc,
        "include": pjoin(home, "include"),
        "lib64": pjoin(home, "lib64"),
    }
    for k, v in iter(cudaconfig.items()):
        if not os.path.exists(v):
            raise EnvironmentError(
                "The CUDA %s path could not be " "located in %s" % (k, v)
            )

    return cudaconfig


def customize_compiler_for_nvcc(self):
    """Inject deep into distutils to customize how the dispatch
    to gcc/nvcc works.

    If you subclass UnixCCompiler, it's not trivial to get your subclass
    injected in, and still have the right customizations (i.e.
    distutils.sysconfig.customize_compiler) run on it. So instead of going
    the OO route, I have this. Note, it's kindof like a wierd functional
    subclassing going on.
    """

    # Tell the compiler it can processes .cu
    self.src_extensions.append(".cu")

    # Save references to the default compiler_so and _comple methods
    default_compiler_so = self.compiler_so
    super = self._compile

    # Now redefine the _compile method. This gets executed for each
    # object but distutils doesn't have the ability to change compilers
    # based on source extension: we add it.
    def _compile(obj, src, ext, cc_args_in, extra_postargs, pp_opts):
        cc_args = cc_args_in.copy()
        if obj.split("/")[-1] == "tempGPU.o":

            postargs = extra_postargs["nvcc"].copy()

            if "-c" in cc_args and "-dc" in postargs:
                cc_args.remove("-c")
                postargs.remove("-dc")

            postargs.append("-dlink")

            self.set_executable("compiler_so", CUDA["nvcc"])

            bashCommand = (
                self.compiler_so
                + cc_args
                + postargs
                + extra_postargs["device_link"]
                + ["-o", obj]
            )

            cmd = ""
            for item in bashCommand:
                cmd += item + " "

            print(cmd)
            process = subprocess.Popen(cmd.split(), stdout=subprocess.PIPE)
            output, error = process.communicate()
            return

        else:
            if os.path.splitext(src)[1] == ".cu" or obj.split("/")[-1] == "tempGPU.o":
                # use the cuda for .cu files
                try:
                    self.set_executable("compiler_so", CUDA["nvcc"])
                    # use only a subset of the extra_postargs, which are 1-1
                    # translated from the extra_compile_args in the Extension class
                    postargs = extra_postargs["nvcc"]

                    if "-c" in cc_args and "-dc" in postargs:
                        cc_args.remove("-c")

                except NameError:
                    postargs = extra_postargs["gcc"]
                    # cc_args.insert(0, "-x c")
            else:
                postargs = extra_postargs["gcc"]

        super(obj, src, ext, cc_args, postargs, pp_opts)
        # Reset the default compiler_so, which we might have changed for cuda
        self.compiler_so = default_compiler_so

    # Inject our redefined _compile method into the class
    self._compile = _compile


# Run the customize_compiler
class custom_build_ext(build_ext):
    def build_extensions(self):
        self.force = True
        customize_compiler_for_nvcc(self.compiler)
        build_ext.build_extensions(self)

    def build_extension(self, ext):
        sources = ext.sources
        if sources is None or not isinstance(sources, (list, tuple)):
            raise DistutilsSetupError(
                "in 'ext_modules' option (extension '%s'), "
                "'sources' must be present and must be "
                "a list of source filenames" % ext.name
            )
        sources = list(sources)

        ext_path = self.get_ext_fullpath(ext.name)
        depends = sources + ext.depends
        if not (self.force or newer_group(depends, ext_path, "newer")):
            log.debug("skipping '%s' extension (up-to-date)", ext.name)
            return
        else:
            log.info("building '%s' extension", ext.name)

        # First, scan the sources for SWIG definition files (.i), run
        # SWIG on 'em to create .c files, and modify the sources list
        # accordingly.
        sources = self.swig_sources(sources, ext)

        # Next, compile the source code to object files.

        # XXX not honouring 'define_macros' or 'undef_macros' -- the
        # CCompiler API needs to change to accommodate this, and I
        # want to do one thing at a time!

        # Two possible sources for extra compiler arguments:
        #   - 'extra_compile_args' in Extension object
        #   - CFLAGS environment variable (not particularly
        #     elegant, but people seem to expect it and I
        #     guess it's useful)
        # The environment variable should take precedence, and
        # any sensible compiler will give precedence to later
        # command line args.  Hence we combine them in order:
        extra_args = ext.extra_compile_args or []

        macros = ext.define_macros[:]
        for undef in ext.undef_macros:
            macros.append((undef,))

        try:
            CUDA["lib64"]
            run_cuda = True

        except NameError:
            run_cuda = False

        objects = self.compiler.compile(
            sources,
            output_dir=self.build_temp,
            macros=macros,
            include_dirs=ext.include_dirs,
            debug=self.debug,
            extra_postargs=extra_args,
            depends=ext.depends,
        )

        # XXX outdated variable, kept here in case third-part code
        # needs it.
        self._built_objects = objects[:]

        run_cuda = True
        if run_cuda:
            device_link_sources = ["tempGPU.cu"]

            extra_args["device_link"] = self._built_objects
            objects_device_link = self.compiler.compile(
                device_link_sources,
                output_dir=self.build_temp,
                macros=macros,
                include_dirs=ext.include_dirs,
                debug=self.debug,
                extra_postargs=extra_args,
                depends=ext.depends,
            )
            objects += objects_device_link

        # Now link the object files together into a "shared object" --
        # of course, first we have to figure out all the other things
        # that go into the mix.
        if ext.extra_objects:
            objects.extend(ext.extra_objects)
        extra_args = ext.extra_link_args or []

        # Detect target language, if not provided
        language = ext.language or self.compiler.detect_language(sources)

        self.compiler.link_shared_object(
            objects,
            ext_path,
            libraries=self.get_libraries(ext),
            library_dirs=ext.library_dirs,
            runtime_library_dirs=ext.runtime_library_dirs,
            extra_postargs=extra_args,
            export_symbols=self.get_export_symbols(ext),
            debug=self.debug,
            build_temp=self.build_temp,
            target_lang=language,
        )


try:
    CUDA = locate_cuda()
    run_cuda_install = True
except OSError:
    run_cuda_install = False

# Obtain the numpy include directory. This logic works across numpy versions.
try:
    numpy_include = numpy.get_include()
except AttributeError:
    numpy_include = numpy.get_numpy_include()


lib_gsl_dir = "/opt/local/lib"
include_gsl_dir = "/opt/local/include"

if run_cuda_install:
    ext_gpu = Extension(
        "gpuPhenomHM",
        sources=[
            "src/createGPUHolders.cu",
            "src/globalPhenomHM.cpp",
            "src/RingdownCW.cpp",
            "src/fdresponse.cpp",
            "src/IMRPhenomD_internals.cu",
            "src/IMRPhenomD.cu",
            "src/PhenomHM.cu",
            "src/kernel_response.cu",
            "src/kernel.cu",
            "src/interpolate.cu",
            "src/likelihood.cu",
            "src/manager.cu",
            "phenomhm/gpuPhenomHM.pyx",
        ],
        library_dirs=[lib_gsl_dir, CUDA["lib64"]],
        libraries=["cudart", "cublas", "cusparse", "gsl", "gslcblas", "gomp"],
        language="c++",
        runtime_library_dirs=[CUDA["lib64"]],
        # This syntax is specific to this build system
        # we're only going to use certain compiler args with nvcc
        # and not with gcc the implementation of this trick is in
        # customize_compiler()
        extra_compile_args={
            "gcc": [],  # '-g'],
            "nvcc": [
                "-arch=sm_70",
                # "-gencode=arch=compute_35,code=sm_35",
                # "-gencode=arch=compute_50,code=sm_50",
                # "-gencode=arch=compute_52,code=sm_52",
                # "-gencode=arch=compute_60,code=sm_60",
                # "-gencode=arch=compute_61,code=sm_61",
                "-gencode=arch=compute_70,code=sm_70",
                "--default-stream=per-thread",
                "--ptxas-options=-v",
                "-dc",
                "--compiler-options",
                "'-fPIC'",
                "-Xcompiler",
                "-fopenmp",
            ],  # ,"-G", "-g"] # for debugging
        },
        include_dirs=[numpy_include, include_gsl_dir, CUDA["include"], "src"],
    )

    shutil.copy("phenomhm/gpuPhenomHM.pyx", "phenomhm/gpuPhenomHM_glob.pyx")

    ext_gpu_glob = Extension(
        "gpuPhenomHM_glob",
        sources=[
            "src/createGPUHolders.cu",
            "src/globalPhenomHM.cpp",
            "src/RingdownCW.cpp",
            "src/fdresponse.cpp",
            "src/IMRPhenomD_internals.cpp",
            "src/IMRPhenomD.cpp",
            "src/PhenomHM.cpp",
            "src/kernel_response.cu",
            "src/kernel.cu",
            "src/interpolate.cu",
            "src/likelihood.cu",
            "src/manager.cu",
            "phenomhm/gpuPhenomHM_glob.pyx",
        ],
        library_dirs=[lib_gsl_dir, CUDA["lib64"]],
        libraries=["cudart", "cublas", "cusparse", "gsl", "gslcblas", "gomp"],
        language="c++",
        runtime_library_dirs=[CUDA["lib64"]],
        # This syntax is specific to this build system
        # we're only going to use certain compiler args with nvcc
        # and not with gcc the implementation of this trick is in
        # customize_compiler()
        extra_compile_args={
            "gcc": [],  # '-g'],
            "nvcc": [
                "-arch=sm_70",
                # "-gencode=arch=compute_35,code=sm_35",
                # "-gencode=arch=compute_50,code=sm_50",
                # "-gencode=arch=compute_52,code=sm_52",
                # "-gencode=arch=compute_60,code=sm_60",
                # "-gencode=arch=compute_61,code=sm_61",
                "-gencode=arch=compute_70,code=sm_70",
                "--default-stream=per-thread",
                "--ptxas-options=-v",
                "-dc",
                "--compiler-options",
                "'-fPIC'",
                "-lineinfo",
                "-Xcompiler",
                "-fopenmp",
                "-D__GLOBAL_FIT__",
            ],  # ,"-G", "-g"] # for debugging
        },
        include_dirs=[numpy_include, include_gsl_dir, CUDA["include"], "phenomhm/src"],
    )

src_folder = "src/"
for file in os.listdir(src_folder):
    if file.split(".")[-1] == "cu":
        shutil.copy(src_folder + file, src_folder + file[:-2] + "cpp")
shutil.copy("phenomhm/gpuPhenomHM.pyx", "phenomhm/cpuPhenomHM.pyx")
shutil.copy("phenomhm/gpuPhenomHM.pyx", "phenomhm/cpuPhenomHM_glob.pyx")
# Obtain the numpy include directory. This logic works across numpy versions.
try:
    numpy_include = numpy.get_include()
except AttributeError:
    numpy_include = numpy.get_numpy_include()

cwd = os.getcwd()
if cwd == "/home/mlk667/GPU4GW":
    lapack_include = "/software/lapack/3.6.0_gcc/include/"
    lapack_lib = "/software/lapack/3.6.0_gcc/lib/"

else:
    lapack_include = "/usr/local/opt/lapack/include"
    lapack_lib = "/usr/local/opt/lapack/lib"

print(lapack_include)

lib_gsl_dir = "/opt/local/lib"
include_gsl_dir = "/opt/local/include"

ext_cpu = Extension(
    "cpuPhenomHM",
    sources=[
        "src/manager.cu",
        "src/globalPhenomHM.cpp",
        "src/RingdownCW.cpp",
        "src/fdresponse.cpp",
        "src/IMRPhenomD_internals.cpp",
        "src/IMRPhenomD.cpp",
        "src/PhenomHM.cpp",
        "src/kernel.cpp",
        "src/kernel_response.cpp",
        "src/interpolate.cpp",
        "src/likelihood.cpp",
        "phenomhm/cpuPhenomHM.pyx",
    ],
    library_dirs=[lib_gsl_dir, lapack_lib],
    libraries=["gsl", "gslcblas", "pthread", "lapack"],
    language="c++",
    # sruntime_library_dirs = [CUDA['lib64']],
    # This syntax is specific to this build system
    # we're only going to use certain compiler args with nvcc
    # and not with gcc the implementation of this trick is in
    # customize_compiler()
    extra_compile_args={"gcc": ["-O3", "-fopenmp", "-fPIC"]},
    extra_link_args=["-Wl,-rpath,/usr/local/opt/gcc/lib/gcc/9/"],
    include_dirs=[numpy_include, include_gsl_dir, lapack_include, "phenomhm/src"],
)

ext_cpu_glob = Extension(
    "cpuPhenomHM_glob",
    sources=[
        "src/globalPhenomHM.cpp",
        "src/RingdownCW.cpp",
        "src/fdresponse.cpp",
        "src/IMRPhenomD_internals.cpp",
        "src/IMRPhenomD.cpp",
        "src/PhenomHM.cpp",
        "src/kernel.cpp",
        "src/kernel_response.cpp",
        "src/interpolate.cpp",
        "src/likelihood.cpp",
        "src/manager.cpp",
        "phenomhm/cpuPhenomHM_glob.pyx",
    ],
    library_dirs=[lib_gsl_dir, lapack_lib],
    libraries=["gsl", "gslcblas", "pthread", "lapack"],
    language="c++",
    # sruntime_library_dirs = [CUDA['lib64']],
    # This syntax is specific to this build system
    # we're only going to use certain compiler args with nvcc
    # and not with gcc the implementation of this trick is in
    # customize_compiler()
    extra_compile_args={"gcc": ["-O3", "-fopenmp", "-fPIC", "-D__GLOBAL_FIT__"]},
    extra_link_args=["-Wl,-rpath,/usr/local/opt/gcc/lib/gcc/9/"],
    include_dirs=[numpy_include, include_gsl_dir, lapack_include, "phenomhm/src"],
)

if run_cuda_install:
    # extensions = [ext_gpu, ext_cpu]
    extensions = [ext_gpu]  # , ext_gpu_glob]
else:
    print("Did not locate CUDA binary.")
    extensions = [ext_cpu, ext_cpu_glob]

setup(
    name="phenomhm",
    # Random metadata. there's more you can supply
    author="Michael Katz",
    version="0.1",
    packages=["phenomhm", "phenomhm.utils"],
    py_modules=["phenomhm.phenomhm"],
    ext_modules=extensions,
    # Inject our custom trigger
    cmdclass={"build_ext": custom_build_ext},
    # Since the package has c code, the egg cannot be zipped
    zip_safe=False,
)

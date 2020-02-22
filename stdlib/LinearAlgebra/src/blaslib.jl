using Libdl

# We'll initialize these in `__init__()`
const libblas = Ref(C_NULL)
const liblapack = Ref(C_NULL)
const vendor = Ref(:unknown)

# Julia gets ILP64 assumptions baked-in within `build_h.jl`; we use this to choose the `64_`-suffixed
# symbols that exist within libopenblas and MKL.
if Base.USE_BLAS64
    macro blasfunc(x)
        return Expr(:quote, Symbol(x, "64_"))
    end
else
    macro blasfunc(x)
        return Expr(:quote, x)
    end
end


"""
    set_blas_lapack_lib(blaslib, lapacklib)

Set the backing BLAS library for Julia's usage.
"""
function set_blas_lapack_lib(libblas_path::AbstractString, liblapack_path::AbstractString)
    return set_blas_lapack_lib(Libdl.dlopen(libblas_path), Libdl.dlopen(liblapack_path))
end
function set_blas_lapack_lib(new_libblas::Ptr, new_liblapack::Ptr)
    # Ensure that the new blas and lapack have the same BLAS64 setting as we do:
    if determine_blas_ilp64(new_libblas, new_liblapack) != Base.USE_BLAS64
        error("Unable to set BLAS library; ILP64 mismatch detected!")
    end

    libblas[] = new_libblas
    liblapack[] = new_liblapack
    return nothing
end

"""
    determine_blas_vendor(libblas[]::Ptr)

Given a pointer to a loaded BLAS library, determines its vendor. This currently
recognizes only two vendor types, `:openblas` or `:mkl`.  If neither can be 
"""
function determine_blas_vendor(libblas::Ptr)
    vend = :unknown
    if dlsym(libblas, :openblas_set_num_threads; throw_error=false) !== nothing
        vend = :openblas
    elseif dlsym(libblas, :MKL_Set_Num_Threads; throw_error=false) !== nothing
        vend = :mkl
    end
    return vend
end

function determine_blas_ilp64(libblas::Ptr, liblapack::Ptr)
    # First, we look for the presence of `64_`-suffixed names; if those exist,
    # we know we're in ILP64-land!
    if dlsym(libblas, :dgemm_64_; throw_error=false) !== nothing
        return true
    end

    # We do a sanity check for `dgemm_` as a sanity check:
    if dlsym(libblas, :dgemm_; throw_error=false) === nothing
        error("Given BLAS library contains neither `dgemm_` nor `dgemm_64_`!")
    end

    # Otherwise, we run a test by using dpotrf:
    _testmat = Float64[1.0 0.0; 0.0 -1.0]
    info = Ref{Int64}(0)
    lda = Int64(2)
    ccall(dlsym(liblapack, :dpotrf_), Cvoid, (Ref{UInt8}, Ref{Int64}, Ptr{Float64}, Ref{Int64}, Ptr{Int64}),
                                              'U', size(_testmat, 1), _testmat, lda, info)
    # `info == 2` means we succesfully passed parameters to `dpotrf`,
    if info[] == 2
        return true
    elseif info[] == 2^33
        # This means that BLAS/LAPACK are compiled as ILP64
        return false
    else
        error("The LAPACK library produced an undefined error code. Please verify the installation of BLAS and LAPACK.")
    end
end

openblas_get_config() = strip(unsafe_string(ccall(dlsym(libblas[], @blasfunc(openblas_get_config)), Ptr{UInt8}, () )))

"""
    set_num_threads(n)

Set the number of threads the BLAS library should use.
"""
function set_num_threads(n::Integer)
    blas = vendor()
    if blas === :openblas
        return ccall(dlsym(libblas[], @blasfunc(:openblas_set_num_threads)), Cvoid, (Int32,), n)
    elseif blas === :mkl
        # MKL may let us set the number of threads in several ways
        return ccall(dlsym(libblas[], :MKL_Set_Num_Threads), Cvoid, (Cint,), n)
    end

    # OSX BLAS (veclib) looks at an environment variable
    @static if Sys.isapple()
        ENV["VECLIB_MAXIMUM_THREADS"] = n
    end

    return nothing
end

"""
    get_num_threads()

Return the number of threads the BLAS library will use.
"""
function get_num_threads()
    blas = vendor()
    if blas === :openblas
        return ccall(dlsym(libblas[], @blasfunc(:openblas_get_num_threads)), Cint, ())
    elseif blas === :mkl
        return ccall(dlsym(libblas[], :MKL_Get_Num_Threads), Cint, ())
    end

    # OSX BLAS (veclib) looks at an environment variable
    @static if Sys.isapple()
        return tryparse(Cint, get(ENV, "VECLIB_MAXIMUM_THREADS", "1"))
    end

    # Unable to determine, return `nothing`
    return nothing
end
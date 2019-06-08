import numpy as np
cimport numpy as np

assert sizeof(int) == sizeof(np.int32_t)

cdef extern from "src/manager.hh":
    cdef cppclass PhenomHMwrap "PhenomHM":
        PhenomHMwrap(int,
        np.uint32_t *,
        np.uint32_t *,
        int, np.float64_t*,
        np.complex128_t *,
        np.complex128_t *,
        np.complex128_t *, int, np.float64_t*, np.float64_t*, np.float64_t*, int)

        void gen_amp_phase(np.float64_t *, int,
                            double,
                            double,
                            double,
                            double,
                            double,
                            double,
                            double)

        void setup_interp_wave()

        void perform_interp()

        void LISAresponseFD(double, double, double, double, double, double, double)

        void setup_interp_response()

        void Likelihood(np.float64_t*)
        void GetTDI(np.complex128_t*, np.complex128_t*, np.complex128_t*)
        void GetAmpPhase(np.float64_t*, np.float64_t*)

cdef class PhenomHM:
    cdef PhenomHMwrap* g
    cdef int num_modes
    cdef int f_dim
    cdef int data_length

    def __cinit__(self, max_length_init,
     np.ndarray[ndim=1, dtype=np.uint32_t] l_vals,
     np.ndarray[ndim=1, dtype=np.uint32_t] m_vals,
     np.ndarray[ndim=1, dtype=np.float64_t] data_freqs,
     np.ndarray[ndim=1, dtype=np.complex128_t] data_channel1,
     np.ndarray[ndim=1, dtype=np.complex128_t] data_channel2,
     np.ndarray[ndim=1, dtype=np.complex128_t] data_channel3,
     np.ndarray[ndim=1, dtype=np.float64_t] channel1_ASDinv,
     np.ndarray[ndim=1, dtype=np.float64_t] channel2_ASDinv,
     np.ndarray[ndim=1, dtype=np.float64_t] channel3_ASDinv,
     TDItag):

        self.num_modes = len(l_vals)
        self.data_length = len(data_channel1)
        self.g = new PhenomHMwrap(max_length_init,
        &l_vals[0],
        &m_vals[0],
        self.num_modes, &data_freqs[0],
        &data_channel1[0],
        &data_channel2[0],
        &data_channel3[0], self.data_length, &channel1_ASDinv[0], &channel2_ASDinv[0], &channel3_ASDinv[0], TDItag)

    def gen_amp_phase(self, np.ndarray[ndim=1, dtype=np.float64_t] freqs,
                        m1, #solar masses
                        m2, #solar masses
                        chi1z,
                        chi2z,
                        distance,
                        phiRef,
                        f_ref):

        self.f_dim = len(freqs)
        self.g.gen_amp_phase(&freqs[0], self.f_dim,
                                m1, #solar masses
                                m2, #solar masses
                                chi1z,
                                chi2z,
                                distance,
                                phiRef,
                                f_ref)

    def setup_interp_wave(self):
        self.g.setup_interp_wave()
        return

    def LISAresponseFD(self, inc, lam, beta, psi, t0, tRef, merger_freq):
        self.g.LISAresponseFD(inc, lam, beta, psi, t0, tRef, merger_freq)
        return

    def setup_interp_response(self):
        self.g.setup_interp_response()
        return

    def perform_interp(self):
        self.g.perform_interp()
        return

    def Likelihood(self):
        cdef np.ndarray[ndim=1, dtype=np.float64_t] like_out_ = np.zeros((2,), dtype=np.float64)
        self.g.Likelihood(&like_out_[0])
        return like_out_

    def GetTDI(self):
        cdef np.ndarray[ndim=1, dtype=np.complex128_t] X_ = np.zeros((self.data_length,), dtype=np.complex128)
        cdef np.ndarray[ndim=1, dtype=np.complex128_t] Y_ = np.zeros((self.data_length,), dtype=np.complex128)
        cdef np.ndarray[ndim=1, dtype=np.complex128_t] Z_ = np.zeros((self.data_length,), dtype=np.complex128)

        self.g.GetTDI(&X_[0], &Y_[0], &Z_[0])

        return (X_, Y_, Z_)

    def GetAmpPhase(self):
        cdef np.ndarray[ndim=1, dtype=np.float64_t] amp_ = np.zeros((self.f_dim*self.num_modes,), dtype=np.float64)
        cdef np.ndarray[ndim=1, dtype=np.float64_t] phase_ = np.zeros((self.f_dim*self.num_modes,), dtype=np.float64)

        self.g.GetAmpPhase(&amp_[0], &phase_[0])

        return (amp_.reshape(self.num_modes, self.f_dim), phase_.reshape(self.num_modes, self.f_dim))

    def WaveformThroughLikelihood(self, np.ndarray[ndim=1, dtype=np.float64_t] freqs,
                        m1, #solar masses
                        m2, #solar masses
                        chi1z,
                        chi2z,
                        distance,
                        phiRef,
                        f_ref, inc, lam, beta, psi, t0, tRef, merger_freq, return_amp_phase=False, return_TDI=False):
        self.gen_amp_phase(freqs,
                            m1, #solar masses
                            m2, #solar masses
                            chi1z,
                            chi2z,
                            distance,
                            phiRef,
                            f_ref)

        if return_amp_phase:
            return self.GetAmpPhase()

        self.LISAresponseFD(inc, lam, beta, psi, t0, tRef, merger_freq)
        self.setup_interp_wave()
        self.setup_interp_response()
        self.perform_interp()

        if return_TDI:
            return self.GetTDI()

        return self.Likelihood()

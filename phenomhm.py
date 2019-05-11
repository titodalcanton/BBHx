import numpy as np
from scipy import constants as ct

import tdi

try:
    from gpuPhenomHM import PhenomHM
except ImportError:
    from PhenomHM import PhenomHM

MTSUN = 1.989e30*ct.G/ct.c**3


class PhenomHMLikelihood:
    def __init__(self, max_length_init, l_vals,  m_vals, data_freqs, data_stream, t0, **kwargs):
        """
        data_stream (dict): keys X, Y, Z or A, E, T
        """
        prop_defaults = {
            'TDItag': 'AET',  # AET or XYZ
            'max_dimensionless_freq': 0.1,
            'min_dimensionless_freq': 1e-4,
            'data_stream_whitened': True,
            'data_params': {},
            'log_scaled_likelihood': True,
            'eps': 1e-7,
            'test_inds': None,
            'num_params': 12,
        }

        for prop, default in prop_defaults.items():
            setattr(self, prop, kwargs.get(prop, default))

        self.t0 = t0
        self.max_length_init = max_length_init
        self.l_vals, self.m_vals = l_vals, m_vals
        self.data_freqs, self.data_stream = data_freqs, data_stream

        if self.test_inds is None:
            self.test_inds = np.arange(self.num_params)

        if self.TDItag not in ['AET', 'XYZ']:
            raise ValueError('TDItag must be AET or XYZ.')

        if self.data_stream is {} or self.data_stream is None:
            if self.data_params is {}:
                raise ValueError('If data_stream is empty dict or None,'
                                 + 'user must supply data_params kwarg as'
                                 + 'dict with params for data stream.')
            kwargs['data_params']['t0'] = t0
            self.data_freqs, self.data_stream = (create_data_set(l_vals,  m_vals, t0,
                                self.data_params, data_freqs=data_freqs, **kwargs))
            self.data_stream_whitened = False

        for i, channel in enumerate(self.TDItag):
            if channel not in self.data_stream:
                raise KeyError('{} not in TDItag {}.'.format(channel, self.TDItag))

            setattr(self, 'data_channel{}'.format(i+1), self.data_stream[channel])
        additional_factor = np.ones_like(self.data_freqs)
        if self.log_scaled_likelihood:
            additional_factor[1:] = np.sqrt(np.diff(self.data_freqs))
            additional_factor[0] = additional_factor[1]

        if self.TDItag == 'AET':
            self.TDItag_in = 2
            self.channel1_ASDinv = 1./np.sqrt(tdi.noisepsd_AE(self.data_freqs, model='SciRDv1'))*additional_factor
            self.channel2_ASDinv = 1./np.sqrt(tdi.noisepsd_AE(self.data_freqs, model='SciRDv1'))*additional_factor
            self.channel3_ASDinv = 1./np.sqrt(tdi.noisepsd_T(self.data_freqs, model='SciRDv1'))*additional_factor

        elif self.TDItag == 'XYZ':
            self.TDItag_in = 1
            for i in range(1, 4):
                temp = np.sqrt(tdi.noisepsd_XYZ(self.data_freqs, model='SciRDv1'))*additional_factor
                setattr(self, 'channel{}_ASDinv'.format(i), temp)

        if self.data_stream_whitened is False:
            for i in range(1, 4):
                temp = (getattr(self, 'data_channel{}'.format(i)) *
                        getattr(self, 'channel{}_ASDinv'.format(i)))
                setattr(self, 'data_channel{}'.format(i), temp)

        self.d_d = 4*np.sum([np.abs(self.data_channel1)**2, np.abs(self.data_channel2)**2, np.abs(self.data_channel3)**2])

        self.generator = PhenomHM(self.max_length_init,
                          self.l_vals, self.m_vals,
                          self.data_freqs, self.data_channel1,
                          self.data_channel2, self.data_channel3,
                          self.channel1_ASDinv, self.channel2_ASDinv, self.channel3_ASDinv,
                          self.TDItag_in)

    def NLL(self, m1, m2, a1, a2, distance,
                 phiRef, fRef, inc, lam, beta,
                 psi, tRef, freqs=None, return_amp_phase=False, return_TDI=False):

        Msec = (m1+m2)*MTSUN
        # merger frequency for 22 mode amplitude in phenomD
        merger_freq = 0.018/Msec

        if freqs is None:
            upper_freq = self.max_dimensionless_freq/Msec
            lower_freq = self.min_dimensionless_freq/Msec
            freqs = np.logspace(np.log10(lower_freq), np.log10(upper_freq), self.max_length_init)

        out = self.generator.WaveformThroughLikelihood(freqs,
                                              m1, m2,  # solar masses
                                              a1, a2,
                                              distance, phiRef, fRef,
                                              inc, lam, beta, psi,
                                              self.t0, tRef, merger_freq,
                                              return_amp_phase=return_amp_phase,
                                              return_TDI=return_TDI)

        if return_amp_phase or return_TDI:
            return out

        d_h, h_h = out
        return self.d_d + h_h - 2*d_h

    def getNLL(self, x):
        ln_m1, ln_m2, a1, a2, ln_distance, phiRef, fRef, inc, lam, beta, psi, tRef = x
        distance = np.exp(ln_distance)*1e6*ct.parsec  # Mpc to meters
        #mT = np.exp(ln_mT)
        #m1 = mT/(1+mr)
        #m2 = mT*mr/(1+mr)
        m1 = np.exp(ln_m1)
        m2 = np.exp(ln_m2)

        return self.NLL(m1, m2, a1, a2, distance,
                            phiRef, fRef, inc, lam, beta,
                            psi, tRef)

    def gradNLL(self, x):
        grad = np.zeros_like(self.test_inds, dtype=x.dtype)
        for j, i in enumerate(self.test_inds):
            # different for ln dist
            if i == 4:
                grad[j] = -1*self.getNLL(x_trans)

            x_trans = x.copy()
            x_real = x[i]
            x_trans[i] = (1.0 - self.eps)*x_real
            like_down = self.getNLL(x_trans)
            #x_trans.tofile(self.likelihood_file, sep='\t', format='%e')
            #self.likelihood_file.write('{}\t{}\n'.format())

            x_trans[i] = (1.0 + self.eps)*x_real
            like_up = self.getNLL(x_trans)

            grad[j] = (like_up - like_down)/(2*self.eps*x_real)

        return grad

    def get_Mij(self, x):
        Mij = np.zeros_like(self.test_inds, dtype=x.dtype)
        for j, i in enumerate(self.test_inds):
            # different for ln dist
            if i == 4:
                Mij[j] = self.getNLL(x)

            f_x = self.getNLL(x)
            x_trans = x.copy()
            x_real = x[i]
            x_trans[i] = (1.0 - 2*self.eps)*x_real  # 2 is from second order central difference
            like_down = self.getNLL(x_trans)

            x_trans[i] = (1.0 + 2*self.eps)*x_real  # 2 is from second order central difference
            like_up = self.getNLL(x_trans)

            Mij[j] = (like_up - 2*f_x + like_down)/(4*(self.eps*x_real)**2)
        print('finished Mij')
        return Mij


def create_data_set(l_vals,  m_vals, t0, waveform_params, data_freqs=None, TDItag='AET', num_data_points=int(2**19), num_generate_points=int(2**18), df=None, fmin=None, fmax=None, **kwargs):
    if data_freqs is None:
        m1 = waveform_params['m1']
        m2 = waveform_params['m2']
        Msec = (m1+m2)*MTSUN
        upper_freq = 0.1/Msec
        lower_freq = 1e-4/Msec
        merger_freq = 0.018/Msec
        if df is None:
            data_freqs = np.logspace(np.log10(lower_freq), np.log10(upper_freq), num_data_points)
        else:
            data_freqs = np.arange(fmin, fmax+df, df)

    generate_freqs = np.logspace(np.log10(data_freqs.min()), np.log10(data_freqs.max()), num_generate_points)

    fake_data = np.zeros_like(data_freqs, dtype=np.complex128)
    fake_ASD = np.ones_like(data_freqs)

    if TDItag == 'AET':
        TDItag_in = 2

    elif TDItag == 'XYZ':
        TDItag_in = 1

    phenomHM = PhenomHM(len(generate_freqs), l_vals, m_vals, data_freqs, fake_data, fake_data, fake_data, fake_ASD, fake_ASD, fake_ASD, TDItag_in)

    phenomHM.gen_amp_phase(generate_freqs, waveform_params['m1'],  # solar masses
                 waveform_params['m2'],  # solar masses
                 waveform_params['a1'],
                 waveform_params['a2'],
                 waveform_params['distance'],
                 waveform_params['phiRef'],
                 waveform_params['fRef'])

    phenomHM.setup_interp_wave()
    phenomHM.LISAresponseFD(waveform_params['inc'], waveform_params['lam'], waveform_params['beta'], waveform_params['psi'], waveform_params['t0'], waveform_params['tRef'], merger_freq)
    phenomHM.setup_interp_response()
    phenomHM.perform_interp()

    channel1, channel2, channel3 = phenomHM.GetTDI()

    channel1, channel2, channel3 = channel1.sum(axis=0), channel2.sum(axis=0), channel3.sum(axis=0)
    data_stream = {TDItag[0]: channel1, TDItag[1]: channel2, TDItag[2]: channel3}
    return data_freqs, data_stream


if __name__ == "__main__":
    import pdb
    from astropy.cosmology import Planck15 as cosmo
    max_length_init = int(2**12)
    l_vals = np.array([2, 3, 4, 4, 3], dtype=np.uint32)
    m_vals = np.array([2, 3, 4, 3, 2], dtype=np.uint32)
    data_freqs = None
    data_stream = None
    t0 = 1.0*ct.Julian_year

    kwargs = {}
    data_params = {
        'm1': 5e5,
        'm2': 1e5,
        'a1': 0.8,
        'a2': 0.8,
        'distance': cosmo.luminosity_distance(3.0).value*1e6*ct.parsec,
        'fRef': 1e-3,
        'phiRef': 0.0,
        'inc': np.pi/3.,
        'lam': np.pi/4.,
        'beta': np.pi/5.,
        'psi': np.pi/6.,
        'tRef': 3600.0,
    }

    kwargs['data_params'] = data_params.copy()

    test = PhenomHMLikelihood(max_length_init, l_vals,  m_vals, data_freqs, data_stream, t0, **kwargs)

    test_params = {
        'm1': 4.96e5,
        'm2': 1e5,
        'a1': 0.2,
        'a2': 0.,
        'distance': cosmo.luminosity_distance(3.0).value*1e6*ct.parsec,
        'fRef': 1e-3,
        'phiRef': 0.0,
        'inc': np.pi/3.,
        'lam': np.pi/4.,
        'beta': np.pi/5.,
        'psi': np.pi/6.,
        'tRef': 3600.0,
    }

    a1_test = np.linspace(-np.pi/2, np.pi/2-0.000001, 10000)


    arr = np.asarray([getattr(test, 'data_channel{}'.format(i+1)) for i in range(3)])
    d_d = 4*np.sum(arr.conj()*arr).real

    test_params = data_params
    nll = []
    for a1 in a1_test:
        test_params['inc'] = a1
        neg_log_likelihood = test.NLL(**test_params)
        nll.append(neg_log_likelihood)

    np.save('nll_test', np.asarray(nll))
    pdb.set_trace()
/*
This is the central piece of code. This file implements a class
(interface in gpuadder.hh) that takes data in on the cpu side, copies
it to the gpu, and exposes functions (increment and retreive) that let
you perform actions with the GPU

This class will get translated into python via swig
*/

#include <kernel.cu>
//#include <reduction.cu>
#include <manager.hh>
#include <assert.h>
#include <iostream>
#include "globalPhenomHM.h"
#include <complex>
#include "cuComplex.h"
#include "cublas_v2.h"
#include "interpolate.cu"


using namespace std;


#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}


ModeContainer * gpu_create_modes(int num_modes, unsigned int *l_vals, unsigned int *m_vals, int max_length, int to_gpu, int to_interp){
        ModeContainer * cpu_mode_vals = cpu_create_modes(num_modes,  l_vals, m_vals, max_length, 1, 0);
        ModeContainer * mode_vals;

        double *amp[num_modes];
        double *phase[num_modes];

        //cuDoubleComplex *hI[num_modes];
        //cuDoubleComplex *hII[num_modes];

        double *amp_coeff_1[num_modes];
        double *amp_coeff_2[num_modes];
        double *amp_coeff_3[num_modes];

        double *phase_coeff_1[num_modes];
        double *phase_coeff_2[num_modes];
        double *phase_coeff_3[num_modes];


        gpuErrchk(cudaMalloc(&mode_vals, num_modes*sizeof(ModeContainer)));
        gpuErrchk(cudaMemcpy(mode_vals, cpu_mode_vals, num_modes*sizeof(ModeContainer), cudaMemcpyHostToDevice));

        for (int i=0; i<num_modes; i++){
            gpuErrchk(cudaMalloc(&amp[i], max_length*sizeof(double)));
            gpuErrchk(cudaMalloc(&phase[i], max_length*sizeof(double)));

            gpuErrchk(cudaMemcpy(&(mode_vals[i].amp), &(amp[i]), sizeof(double *), cudaMemcpyHostToDevice));
            gpuErrchk(cudaMemcpy(&(mode_vals[i].phase), &(phase[i]), sizeof(double *), cudaMemcpyHostToDevice));

            /*gpuErrchk(cudaMalloc(&hI[i], max_length*sizeof(cuDoubleComplex)));
            gpuErrchk(cudaMalloc(&hII[i], max_length*sizeof(cuDoubleComplex)));

            cudaMemcpy(&(mode_vals[i].hI), &(hI[i]), sizeof(cuDoubleComplex *), cudaMemcpyHostToDevice);
            cudaMemcpy(&(mode_vals[i].hII), &(hII[i]), sizeof(cuDoubleComplex *), cudaMemcpyHostToDevice);*/

            if (to_interp == 1){
                gpuErrchk(cudaMalloc(&amp_coeff_1[i], (max_length-1)*sizeof(double)));
                gpuErrchk(cudaMalloc(&amp_coeff_2[i], (max_length-1)*sizeof(double)));
                gpuErrchk(cudaMalloc(&amp_coeff_3[i], (max_length-1)*sizeof(double)));
                gpuErrchk(cudaMalloc(&phase_coeff_1[i], (max_length-1)*sizeof(double)));
                gpuErrchk(cudaMalloc(&phase_coeff_2[i], (max_length-1)*sizeof(double)));
                gpuErrchk(cudaMalloc(&phase_coeff_3[i], (max_length-1)*sizeof(double)));

                gpuErrchk(cudaMemcpy(&(mode_vals[i].amp_coeff_1), &(amp_coeff_1[i]), sizeof(double *), cudaMemcpyHostToDevice));
                gpuErrchk(cudaMemcpy(&(mode_vals[i].amp_coeff_2), &(amp_coeff_2[i]), sizeof(double *), cudaMemcpyHostToDevice));
                gpuErrchk(cudaMemcpy(&(mode_vals[i].amp_coeff_3), &(amp_coeff_3[i]), sizeof(double *), cudaMemcpyHostToDevice));
                gpuErrchk(cudaMemcpy(&(mode_vals[i].phase_coeff_1), &(phase_coeff_1[i]), sizeof(double *), cudaMemcpyHostToDevice));
                gpuErrchk(cudaMemcpy(&(mode_vals[i].phase_coeff_2), &(phase_coeff_2[i]), sizeof(double *), cudaMemcpyHostToDevice));
                gpuErrchk(cudaMemcpy(&(mode_vals[i].phase_coeff_3), &(phase_coeff_3[i]), sizeof(double *), cudaMemcpyHostToDevice));
            }
        }

        return mode_vals;
}

void gpu_destroy_modes(ModeContainer * mode_vals){
    for (int i=0; i<mode_vals[0].num_modes; i++){
        gpuErrchk(cudaFree(mode_vals[i].amp));
        gpuErrchk(cudaFree(mode_vals[i].phase));
        //gpuErrchk(cudaFree(mode_vals[i].hI));
        //gpuErrchk(cudaFree(mode_vals[i].hII));
        if (mode_vals[i].to_interp == 1){
            gpuErrchk(cudaFree(mode_vals[i].amp_coeff_1));
            gpuErrchk(cudaFree(mode_vals[i].amp_coeff_2));
            gpuErrchk(cudaFree(mode_vals[i].amp_coeff_3));
            gpuErrchk(cudaFree(mode_vals[i].phase_coeff_1));
            gpuErrchk(cudaFree(mode_vals[i].phase_coeff_2));
            gpuErrchk(cudaFree(mode_vals[i].phase_coeff_3));
        }
    }
    gpuErrchk(cudaFree(mode_vals));
}


GPUPhenomHM::GPUPhenomHM (int max_length_,
    unsigned int *l_vals_,
    unsigned int *m_vals_,
    int num_modes_,
    int to_gpu_,
    int to_interp_,
    std::complex<double> *data_stream_, int data_stream_length_){

    max_length = max_length_;
    l_vals = l_vals_;
    m_vals = m_vals_;
    num_modes = num_modes_;
    to_gpu = to_gpu_;
    to_interp = to_interp_;
    data_stream = data_stream_;
    data_stream_length = data_stream_length_;

    cudaError_t err;

    // DECLARE ALL THE  NECESSARY STRUCTS
    pHM_trans = new PhenomHMStorage;

    pAmp_trans = new IMRPhenomDAmplitudeCoefficients;

    amp_prefactors_trans = new AmpInsPrefactors;

    pDPreComp_all_trans = new PhenDAmpAndPhasePreComp[num_modes];

    q_all_trans = new HMPhasePreComp[num_modes];

  mode_vals = cpu_create_modes(num_modes, l_vals, m_vals, max_length, to_gpu, to_interp);

  if (to_gpu == 1){
      cuDoubleComplex * ones = new cuDoubleComplex[num_modes];
      for (int i=0; i<(num_modes); i++) ones[i] = make_cuDoubleComplex(1.0, 0.0);
      gpuErrchk(cudaMalloc(&d_ones, num_modes*sizeof(cuDoubleComplex)));
      gpuErrchk(cudaMemcpy(d_ones, ones, num_modes*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice));
      delete ones;

      gpuErrchk(cudaMalloc(&d_hI, data_stream_length*num_modes*sizeof(cuDoubleComplex)));
      gpuErrchk(cudaMalloc(&d_hII, data_stream_length*num_modes*sizeof(cuDoubleComplex)));

      gpuErrchk(cudaMalloc(&d_hI_out, data_stream_length*sizeof(cuDoubleComplex)));
      gpuErrchk(cudaMalloc(&d_hII_out, data_stream_length*sizeof(cuDoubleComplex)));

      d_mode_vals = gpu_create_modes(num_modes, l_vals, m_vals, max_length, to_gpu, to_interp);

      gpuErrchk(cudaMalloc(&d_freqs, max_length*sizeof(double)));

      gpuErrchk(cudaMalloc(&d_data_stream, data_stream_length*sizeof(cuDoubleComplex)));
      gpuErrchk(cudaMemcpy(d_data_stream, data_stream, data_stream_length*sizeof(cuDoubleComplex), cudaMemcpyHostToDevice));

      //gpuErrchk(cudaMalloc(&d_mode_vals, num_modes*sizeof(d_mode_vals)));
      //gpuErrchk(cudaMemcpy(d_mode_vals, mode_vals, num_modes*sizeof(d_mode_vals), cudaMemcpyHostToDevice));

      // DECLARE ALL THE  NECESSARY STRUCTS
      gpuErrchk(cudaMalloc(&d_pHM_trans, sizeof(PhenomHMStorage)));

      gpuErrchk(cudaMalloc(&d_pAmp_trans, sizeof(IMRPhenomDAmplitudeCoefficients)));

      gpuErrchk(cudaMalloc(&d_amp_prefactors_trans, sizeof(AmpInsPrefactors)));

      gpuErrchk(cudaMalloc(&d_pDPreComp_all_trans, num_modes*sizeof(PhenDAmpAndPhasePreComp)));

      gpuErrchk(cudaMalloc((void**) &d_q_all_trans, num_modes*sizeof(HMPhasePreComp)));


      double cShift[7] = {0.0,
                           PI_2 /* i shift */,
                           0.0,
                           -PI_2 /* -i shift */,
                           PI /* 1 shift */,
                           PI_2 /* -1 shift */,
                           0.0};

      gpuErrchk(cudaMalloc(&d_cShift, 7*sizeof(double)));

      gpuErrchk(cudaMemcpy(d_cShift, &cShift, 7*sizeof(double), cudaMemcpyHostToDevice));


      // for likelihood
      // --------------
      gpuErrchk(cudaMallocHost((cuDoubleComplex**) &result, sizeof(cuDoubleComplex)));

      stat = cublasCreate(&handle);
      if (stat != CUBLAS_STATUS_SUCCESS) {
              printf ("CUBLAS initialization failed\n");
              exit(0);
          }
      // ----------------
  }
  //double t0_;
  t0 = 0.0;

  //double phi0_;
  phi0 = 0.0;

  //double amp0_;
  amp0 = 0.0;
}


void GPUPhenomHM::add_interp(int max_interp_length_){
    max_interp_length = max_interp_length_;

    assert(to_interp == 1);
    if (to_gpu == 0){
        out_mode_vals = cpu_create_modes(num_modes, m_vals, l_vals, max_interp_length, to_gpu, 0);
    }
    if (to_gpu){

        h_indices = new int[max_interp_length];
        cudaMalloc(&d_indices, max_interp_length*sizeof(int));
        //d_out_mode_vals = gpu_create_modes(num_modes, m_vals, l_vals, max_interp_length, to_gpu, 0);
        //h_B = new double[2*f_length*num_modes];
        //h_B1 = new double[2*f_length*num_modes];*/
        gpuErrchk(cudaMalloc(&d_B, 2*max_interp_length_*num_modes*sizeof(double)));
    }
}



void GPUPhenomHM::gpu_gen_PhenomHM(double *freqs_, int f_length_,
    double m1_, //solar masses
    double m2_, //solar masses
    double chi1z_,
    double chi2z_,
    double distance_,
    double inclination_,
    double phiRef_,
    double deltaF_,
    double f_ref_){

    assert((to_gpu == 1) || (to_gpu == 2));

    GPUPhenomHM::cpu_gen_PhenomHM(freqs_, f_length_,
        m1_, //solar masses
        m2_, //solar masses
        chi1z_,
        chi2z_,
        distance_,
        inclination_,
        phiRef_,
        deltaF_,
        f_ref_);

        printf("past\n");
    // Initialize inputs
    //gpuErrchk(cudaMemcpy(d_mode_vals, mode_vals, num_modes*sizeof(ModeContainer), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_freqs, freqs, f_length*sizeof(double), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_pHM_trans, pHM_trans, sizeof(PhenomHMStorage), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_pAmp_trans, pAmp_trans, sizeof(IMRPhenomDAmplitudeCoefficients), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_amp_prefactors_trans, amp_prefactors_trans, sizeof(AmpInsPrefactors), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_pDPreComp_all_trans, pDPreComp_all_trans, num_modes*sizeof(PhenDAmpAndPhasePreComp), cudaMemcpyHostToDevice));

    gpuErrchk(cudaMemcpy(d_q_all_trans, q_all_trans, num_modes*sizeof(HMPhasePreComp), cudaMemcpyHostToDevice));

    double M_tot_sec = (m1+m2)*MTSUN_SI;
    /* main: evaluate model at given frequencies */
    NUM_THREADS = 256;
    num_blocks = std::ceil((f_length + NUM_THREADS -1)/NUM_THREADS);
    dim3 gridDim(num_modes, num_blocks);
    printf("blocks %d\n", num_blocks);
    kernel_calculate_all_modes<<<gridDim, NUM_THREADS>>>(d_mode_vals,
          d_pHM_trans,
          d_freqs,
          M_tot_sec,
          d_pAmp_trans,
          d_amp_prefactors_trans,
          d_pDPreComp_all_trans,
          d_q_all_trans,
          amp0,
          num_modes,
          t0,
          phi0,
          d_cShift
      );
     cudaDeviceSynchronize();
     gpuErrchk(cudaGetLastError());

}


void GPUPhenomHM::cpu_gen_PhenomHM(double *freqs_, int f_length_,
    double m1_, //solar masses
    double m2_, //solar masses
    double chi1z_,
    double chi2z_,
    double distance_,
    double inclination_,
    double phiRef_,
    double deltaF_,
    double f_ref_){

    freqs = freqs_;
    f_length = f_length_;
    m1 = m1_; //solar masses
    m2 = m2_; //solar masses
    chi1z = chi1z_;
    chi2z = chi2z_;
    distance = distance_;
    inclination = inclination_;
    phiRef = phiRef_;
    deltaF = deltaF_;
    f_ref = f_ref_;

    for (int i=0; i<num_modes; i++){
        mode_vals[i].length = f_length;
    }

    m1_SI = m1*MSUN_SI;
    m2_SI = m2*MSUN_SI;

    /* main: evaluate model at given frequencies */
    retcode = 0;
    retcode = IMRPhenomHMCore(
        mode_vals,
        freqs,
        f_length,
        m1_SI,
        m2_SI,
        chi1z,
        chi2z,
        distance,
        inclination,
        phiRef,
        deltaF,
        f_ref,
        num_modes,
        to_gpu,
        pHM_trans,
        pAmp_trans,
        amp_prefactors_trans,
        pDPreComp_all_trans,
        q_all_trans,
        &t0,
        &phi0,
        &amp0);
    assert (retcode == 1); //,PD_EFUNC, "IMRPhenomHMCore failed in

}


__global__ void read_out_kernel2(ModeContainer *mode_vals, double *coef0, double *coef1, double *coef2, double *coef3, int mode_i, int length){
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= length) return;
    coef0[i] = mode_vals[mode_i].amp[i];
    coef1[i] = mode_vals[mode_i].amp_coeff_1[i];
    coef2[i] = mode_vals[mode_i].amp_coeff_2[i];
    coef3[i] = mode_vals[mode_i].amp_coeff_3[i];
    //phase[i] = mode_vals[mode_i].phase[i];
}

__global__ void debug(ModeContainer *mode_vals, int num_modes, int length){
    int i = blockIdx.y * blockDim.x + threadIdx.x;
    int mode_i = blockIdx.x;
    if (mode_i >= num_modes) return;
    if (i >= length) return;
    double amp = mode_vals[mode_i].amp[i];
    double phase = mode_vals[mode_i].phase[i];
    //phase[i] = mode_vals[mode_i].phase[i];
}

void GPUPhenomHM::interp_wave(double f_min, double df, int length_new){

    dim3 check_dim(num_modes, num_blocks);
    int check_num_threads = 256;
    /*debug<<<check_dim, NUM_THREADS>>>(d_mode_vals, num_modes, f_length);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());*/

    fill_B<<<check_dim, NUM_THREADS>>>(d_mode_vals, d_B, f_length, num_modes);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());

    interp.prep(d_B, f_length, 2*num_modes, 1);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());

    set_spline_constants<<<check_dim, NUM_THREADS>>>(d_mode_vals, d_B, f_length, num_modes);

    int num_block_interp = std::ceil((length_new + NUM_THREADS - 1)/NUM_THREADS);
    dim3 interp_dim(num_modes, num_block_interp);
    double d_log10f = log10(freqs[1]) - log10(freqs[0]);
    printf("NUM MODES %d\n", num_modes);
    interpolate<<<interp_dim, NUM_THREADS>>>(d_hI, d_mode_vals, num_modes, f_min, df, d_log10f, d_freqs, length_new);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());
    //TODO need to make this more adaptable (especially for smaller amounts)
    /*int break_num = 100;
    int num_iters = (int)(length_new + break_num - 1)/break_num;
    int left_over = length_new % num_iters;
    //cudaStream_t streams[num_iters];

    int di = (int) length_new/100;
    int i = 0;
    double f = f_min;
    while (f < freqs[0]){
        i++;
        f = f_min + df*i;
    }
    int new_start_index = i;
    int new_end_index;
    int ended = 0;
    int index = 0;
    for (int jj=0; jj<num_iters; jj++){
        if (jj<num_iters-1) di = (int)length_new/break_num;
        else di = left_over;
        for (i; i<di*(jj+1); i++){
            if (f > freqs[f_length-1]){
                new_end_index = i-1;
                ended = 1;
                break;
            }
            f = f_min + df*i;
            if (f < freqs[index + 1]){
                h_indices[i] = index;
            } else{
                index++;
                h_indices[i] = index;
            }
        }
        if (ended == 0) new_end_index = i;
        int num_evals = new_end_index - new_start_index + 1;
        int num_blocks = (int) ((num_evals + NUM_THREADS - 1) / NUM_THREADS);
        dim3 gridDim(num_modes, num_blocks);
        cudaDeviceSynchronize();
        gpuErrchk(cudaGetLastError());

        gpuErrchk(cudaMemcpy(&d_indices[new_start_index], &h_indices[new_start_index], di*sizeof(int), cudaMemcpyHostToDevice));
        interpolate2<<<gridDim, NUM_THREADS>>>(d_hI, d_mode_vals,
            //d_out_mode_vals,
            new_start_index,
            new_end_index,
            num_modes,
            f_min,
            df,
            d_indices,
            d_freqs, length_new);
        if (ended == 1) break;
        new_start_index = new_end_index;
    }
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());*/

}

__device__ __forceinline__ cuDoubleComplex cexp(double amp, double phase){
    return make_cuDoubleComplex(amp*cos(phase), amp*sin(phase));
}

__global__ void convert_to_complex(ModeContainer *mode_vals, cuDoubleComplex *h, int num_modes, int length){
    int i = blockIdx.y * blockDim.x + threadIdx.x;
    int mode_i = blockIdx.x;
    if (i >= length) return;
    if (mode_i >= num_modes) return;
    double amp = mode_vals[mode_i].amp[i];
    double phase = mode_vals[mode_i].phase[i];
    h[mode_i*length + i] = make_cuDoubleComplex(amp*cos(phase), amp*sin(phase));
}

__global__ void debug2(cuDoubleComplex *hI, cuDoubleComplex *hI_out, cuDoubleComplex *ones, int length, int num_modes){
    int i = blockIdx.y * blockDim.x + threadIdx.x;
    int mode_i = blockIdx.x;
    if (mode_i >= num_modes) return;
    if (i >= length) return;
    int j = 0;
    //phase[i] = mode_vals[mode_i].phase[i];
}

int GpuVec(cuDoubleComplex* d_A, cuDoubleComplex* d_x, cuDoubleComplex* d_y, const int row,const int col){
cudaError_t cudastat;
cublasStatus_t stat;
int size=row*col;
cublasHandle_t handle;
/*cuDoubleComplex* d_A;  //device matrix
cuDoubleComplex* d_x;  //device vector
cuDoubleComplex* d_y;  //device result
cudastat=cudaMalloc((void**)&d_A,size*sizeof(cuDoubleComplex));
cudastat=cudaMalloc((void**)&d_x,col*sizeof(cuDoubleComplex));
cudastat=cudaMalloc((void**)&d_y,row*sizeof(cuDoubleComplex));// when I copy y to d_y ,can I cout d_y?

cudaMemcpy(d_A,A,sizeof(cuDoubleComplex)*size,cudaMemcpyHostToDevice);  //copy A to device d_A
cudaMemcpy(d_x,x,sizeof(cuDoubleComplex)*col,cudaMemcpyHostToDevice);*/   //copy x to device d_x

cuDoubleComplex alf=make_cuDoubleComplex(1.0,0.0);
cuDoubleComplex beta=make_cuDoubleComplex(0.0,0.0);
    stat=cublasCreate(&handle);
/*int NUM_THREADS = 256;
int num_blockshere = (int)(row + NUM_THREADS -1)/NUM_THREADS;
dim3 likeDim(col, num_blockshere);
debug2<<<likeDim, NUM_THREADS>>>(d_A, d_y, d_x, row, col);
cudaDeviceSynchronize();
gpuErrchk(cudaGetLastError());*/
stat=cublasZgemv(handle,CUBLAS_OP_T,col,row,&alf,d_A,col,d_x,1,&beta,d_y,1);//swap col and row
/*cudaMemcpy(y,d_y,sizeof(cuDoubleComplex)*row,cudaMemcpyDeviceToHost); // copy device result to host
cudaFree(d_A);
cudaFree(d_x);
cudaFree(d_y);*/
cublasDestroy(handle);
return 0;
}


double GPUPhenomHM::Likelihood (int like_length){

    if (to_interp == 0){
        int num_blockshere = (int)(like_length + NUM_THREADS -1)/NUM_THREADS;
        dim3 likeDim(num_modes, num_blockshere);
        convert_to_complex<<<likeDim, NUM_THREADS>>>(d_mode_vals, d_hI, num_modes, like_length);
        cudaDeviceSynchronize();
        gpuErrchk(cudaGetLastError());
    }


    /*debug2<<<likeDim, NUM_THREADS>>>(d_hI, d_hI_out, d_ones, like_length, num_modes);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());*/

    GpuVec(d_hI, d_ones, d_hI_out, like_length, num_modes);
    /*cuDoubleComplex alpha = make_cuDoubleComplex(1.0,0.0);
    cuDoubleComplex beta = make_cuDoubleComplex(0.0,0.0);

    stat = cublasZgemv(handle, CUBLAS_OP_N,
                           like_length, num_modes,
                           &alpha,
                           d_hI, like_length,
                           d_ones, 1,
                           &beta,
                           d_hI_out, 1);
    status = _cudaGetErrorEnum(stat);
     cudaDeviceSynchronize();
     printf ("%s\n", status);
     if (stat != CUBLAS_STATUS_SUCCESS) {
             exit(0);
         }*/
     //gpuErrchk(cudaGetLastError());


     char * status;
    stat = cublasZdotc(handle, like_length,
            d_hI_out, 1,
            d_data_stream, 1,
            result);
    status = _cudaGetErrorEnum(stat);
     cudaDeviceSynchronize();
     printf ("%s\n", status);
     if (stat != CUBLAS_STATUS_SUCCESS) {
             exit(0);
         }
    //gpuErrchk(cudaGetLastError());


    return cuCreal(result[0]);
    //return 0.0;
}

void GPUPhenomHM::Get_Waveform (int mode_i, double* amp_, double* phase_) {
    assert(to_gpu == 0);
    memcpy(amp_, mode_vals[mode_i].amp, f_length*sizeof(double));
    memcpy(phase_, mode_vals[mode_i].phase, f_length*sizeof(double));
}

__global__ void read_out_kernel(ModeContainer *mode_vals, double *amp, double *phase, int mode_i, int length){
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= length) return;
    amp[i] = mode_vals[mode_i].amp[i];
    phase[i] = mode_vals[mode_i].phase[i];
}

void GPUPhenomHM::gpu_Get_Waveform (std::complex<double>* hI_) {
  assert(to_gpu == 1);
  gpuErrchk(cudaMemcpy(hI_, d_hI, max_interp_length*num_modes*sizeof(std::complex<double>), cudaMemcpyDeviceToHost));

  //int num_blocks = (int)((max_interp_length + NUM_THREADS - 1)/NUM_THREADS);
  //gpuErrchk(cudaMalloc(&amp, f_length*sizeof(double)));
  //gpuErrchk(cudaMalloc(&phase, f_length*sizeof(double)));
  //read_out_kernel<<<num_blocks,NUM_THREADS>>>(d_mode_vals, amp, phase, mode_i, f_length);
  //gpuErrchk(cudaMalloc(&amp, max_interp_length*sizeof(double)));
  //gpuErrchk(cudaMalloc(&phase, max_interp_length*sizeof(double)));
  //read_out_kernel<<<num_blocks,NUM_THREADS>>>(d_out_mode_vals, amp, phase, mode_i, max_interp_length);

  //cudaDeviceSynchronize();
  //gpuErrchk(cudaGetLastError());
  /*double *amp;
  double *phase;
  gpuErrchk(cudaMalloc(&amp, f_length*sizeof(double)));
  gpuErrchk(cudaMalloc(&phase, f_length*sizeof(double)));

  cudaMemcpy(&(amp), &(mode_vals[mode_i].amp),sizeof(double *), cudaMemcpyDeviceToHost);
  cudaMemcpy(&(phase), &(mode_vals[mode_i].phase), sizeof(double *), cudaMemcpyDeviceToHost);

    gpuErrchk(cudaMemcpy(amp_, amp, f_length*sizeof(double), cudaMemcpyDeviceToHost));

    gpuErrchk(cudaMemcpy(phase_, phase, f_length*sizeof(double), cudaMemcpyDeviceToHost));
    */
    //printf("max_interp_length: %d \n", max_interp_length);
    //gpuErrchk(cudaMemcpy(amp_, amp, max_interp_length*sizeof(double), cudaMemcpyDeviceToHost));
    //gpuErrchk(cudaMemcpy(phase_, phase, max_interp_length*sizeof(double), cudaMemcpyDeviceToHost));
    //cudaFree(amp);
    //cudaFree(phase);

}

GPUPhenomHM::~GPUPhenomHM() {
  delete pHM_trans;
  delete pAmp_trans;
  delete amp_prefactors_trans;
  delete pDPreComp_all_trans;
  delete q_all_trans;
  cpu_destroy_modes(mode_vals);

  if (to_gpu == 1){
      cudaFree(d_ones);
      cudaFree(d_hI);
      cudaFree(d_hII);
      cudaFree(d_hI_out);
      cudaFree(d_hII_out);
      cudaFree(d_freqs);
      cudaFree(d_data_stream);
      gpu_destroy_modes(d_mode_vals);
      cudaFree(d_pHM_trans);
      cudaFree(d_pAmp_trans);
      cudaFree(d_amp_prefactors_trans);
      cudaFree(d_pDPreComp_all_trans);
      cudaFree(d_q_all_trans);
      cudaFree(d_cShift);
      cudaFree(result);
      cublasDestroy(handle);
  }
  if (to_interp == 1){
      delete h_indices;
      cudaFree(d_indices);
      cpu_destroy_modes(out_mode_vals);
      cudaFree(d_B);
      //gpu_destroy_modes(d_out_mode_vals);
      //delete interp;
  }
}

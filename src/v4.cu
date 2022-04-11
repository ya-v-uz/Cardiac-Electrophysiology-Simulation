/* 
* Solves the Panfilov model using an explicit numerical scheme.
* Based on code orginally provided by Xing Cai, Simula Research Laboratory
*and reimplementation by Scott B. Baden, UCSD
*
* Modified and restructured by Didem Unat, Koc Universiy_thread
*
* Refer to "Detailed Numerical Analyses of the Aliev-Panfilov Model on GPGPU"
* https://www.simula.no/publications/detailed-numerical-analyses-aliev-panfilov-model-gpgpu
*by Xing Cai, Didem Unat and Scott Baden
*
*/

#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <iostream>
#include <iomanip>
#include <string.h>
#include <math.h>
#include <sys/time.h>
#include <getopt.h>

using namespace std;

// External functions
extern "C" void splot(double *E, double T, int niter, int m, int n);

void cmdLine(int argc, char* argv[], double& T, int& n, int& px, int& py, int& plot_freq, int& kernel_no);

// Utilities
// 

// Timer
// Make successive calls and take a difference to get the elapsed time.
static const double kMicro = 1.0e-6;
double getTime()
{
    struct timeval TV;
    struct timezone TZ;

    const int RC = gettimeofday(&TV, &TZ);
    if (RC == -1) {
        cerr << "ERROR: Bad call to gettimeofday" << endl;
        return(-1);
    }

    return(((double)TV.tv_sec) + kMicro * ((double)TV.tv_usec));

}  // end getTime()

// Allocate a 2D array
double **alloc2D(int m, int n) {
    double **E;
    int nx = n, ny = m;
    E = (double**)malloc(sizeof(double*) * ny + sizeof(double) * nx * ny);
    assert(E);
    int j;
    for (j = 0;j < ny;j++)
        E[j] = (double*)(E + ny) + j * nx;
    return(E);
}

// Reports statistics about the computation
// These values should not vary (except to within roundoff)
// when we use different numbers of  processes to solve the problem
double stats(double *E, int m, int n, double *_mx) {
	double mx = -1;
	double l2norm = 0;
	int i, j;
	for (j = 1; j <= m; j++) {
	  for (i = 1; i <= n; i++) {
		  l2norm += E[j * (n+2) + i] * E[j * (n+2) + i];
		  if (E[j * (n+2) + i] > mx) 
              mx = E[j * (n+2) + i];
			}
	}
	*_mx = mx;
	l2norm /= (double) ((m) * (n));
	l2norm = sqrt(l2norm);
	return l2norm;
}



__global__ void ghostKernel(double *E_prev, const int n, const int m) {
    int j = threadIdx.x + 1;

    E_prev[j * (n+2)] = E_prev[j * (n+2) + 2];
    E_prev[j * (n+2) + (n + 1)] = E_prev[j * (n + 2) + (n - 1)];

    E_prev[j] = E_prev[2 * (n + 2) + j];
    E_prev[(m + 1) * (n + 2) + j] = E_prev[(m - 1) * (n + 2) + j];
}

__global__ void singleKernel(double *E, double *E_prev, double *R,
    const int n, const int m, const double kk,
    const double dt, const double a, const double epsilon,
    const double M1, const double M2, const double b, const double alpha) {
   
    int x_thread = threadIdx.x, y_thread = threadIdx.y, x_block = blockIdx.x, y_block = blockIdx.y, x_blockDim = blockDim.x, y_blockDim = blockDim.y;
   const int block_size = 16;
    
    __shared__ double device_memory_array[block_size + 2][block_size + 2];     
    
    if(x_thread == 0) {
        int index = (y_block * y_blockDim * (n + 2)) + (x_block * x_blockDim) + ((y_thread + 1) * (n + 2));
        for (int j = 0; j < x_blockDim + 2; j++) {
            device_memory_array[y_thread + 1][j] = E_prev[index + j];
        }
        if(y_thread == 0) {
            int index = (y_block * y_blockDim * (n + 2)) + (x_block * x_blockDim);    
            for (int j = 0; j < x_blockDim + 2; j++) {
                device_memory_array[0][j] = E_prev[index + j];
            }
        }
        if(y_thread == 1) {
            int index = (y_block * y_blockDim * (n + 2)) + (x_block * x_blockDim) + ((y_blockDim + 1) * (n + 2));
    
            for (int j = 0; j < x_blockDim + 2; j++) {
                device_memory_array[y_blockDim + 1][j] = E_prev[index + j];
            }
        }
    }
    
    int index = (y_block * y_blockDim * (n + 2)) + (x_block * x_blockDim) + (n + 2) + 1 + (y_thread * (n + 2) + x_thread);
    
    __syncthreads();
    double E_temp = E[index]; 
    double R_temp = R[index];
     
    E_temp = device_memory_array[y_thread + 1][x_thread + 1] + alpha * (device_memory_array[y_thread + 1][x_thread + 2] + device_memory_array[y_thread + 1][x_thread] - 4 * device_memory_array[y_thread + 1][x_thread + 1] + device_memory_array[y_thread + 2][x_thread + 1] + device_memory_array[y_thread][x_thread + 1]);
    E_temp = E_temp - dt * (kk * E_temp * (E_temp - a) * (E_temp - 1) + E_temp * R_temp);
    R_temp = R_temp + dt * (epsilon + M1 * R_temp / (E_temp + M2)) * (-R_temp - kk * E_temp * (E_temp - b - 1));

    __syncthreads();
    E[index] = E_temp;
    R[index] = R_temp;
 }

void simulate(double *E, double *E_prev, double *R,
              const double alpha, const int n, const int m, const double kk,
              const double dt, const double a, const double epsilon,
              const double M1, const double M2, const double b) {
    
    const dim3 block_size(16,16);
    const dim3 num_blocks(n / block_size.x, n / block_size.y);

    ghostKernel<<<1, n>>>(E_prev, n, m);
    singleKernel<<<num_blocks, block_size>>>(E, E_prev, R, n, m, kk, dt, a, epsilon, M1, M2, b, alpha);
}

// Main program
int main(int argc, char** argv)
{
    /*
     *  Solution arrays
     *   E is the "Excitation" variable, a voltage
     *   R is the "Recovery" variable
     *   E_prev is the Excitation variable for the previous timestep,
     *      and is used in time integration
     */
    double *E, *R, *E_prev;
    double *d_E, *d_R, *d_E_prev;

    // Various constants - these definitions shouldn't change
    const double a = 0.1, b = 0.1, kk = 8.0, M1 = 0.07, M2 = 0.3, epsilon = 0.01, d = 5e-5;

    double T = 1000.0;
    int m = 200, n = 200;
    int plot_freq = 0;
    int bx = 1, by = 1;
    int kernel = 1;

    cmdLine(argc, argv, T, n, bx, by, plot_freq, kernel);
    m = n;
    // Allocate contiguous memory for solution arrays
    // The computational box is defined on [1:m+1,1:n+1]
    // We pad the arrays in order to facilitate differencing on the 
    // boundaries of the computation box
    E = (double *) malloc(sizeof(double) * size_t((m + 2) * (n + 2)));
    E_prev = (double *) malloc(sizeof(double) * size_t((m + 2) * (n + 2)));
    R = (double *) malloc(sizeof(double) * size_t((m + 2) * (n + 2)));

    int i, j;
    // Initialization
    for (j = 1; j <= m; j++)
        for (i = 1; i <= n; i++)
            E_prev[j * (n+2) + i] = R[j * (n+2) + i] = 0;

    for (j = 1; j <= m; j++)
        for (i = n / 2 + 1; i <= n; i++)
            E_prev[j * (n+2) + i] = 1.0;

    for (j = m / 2 + 1; j <= m; j++)
        for (i = 1; i <= n; i++)
            R[j * (n+2) + i] = 1.0;

    double dx = 1.0 / n;

    // For time integration, these values shouldn't change 
    double rp = kk * (b + 1) * (b + 1) / 4;
    double dte = (dx * dx) / (d * 4 + ((dx * dx)) * (rp + kk));
    double dtr = 1 / (epsilon + ((M1 / M2) * rp));
    double dt = (dte < dtr) ? 0.95 * dte : 0.95 * dtr;
    double alpha = d * dt / (dx * dx);

    cout << "Grid Size       : " << n << endl;
    cout << "Duration of Sim : " << T << endl;
    cout << "Time step dt    : " << dt << endl;
    cout << "Block Size: " << bx << " x " << by << endl;
    cout << "Using CUDA Kernel Version: " << kernel << endl;

    cout << endl;

    // Start the timer
    double t0 = getTime();


    // Simulated time is different from the integer timestep number
    // Simulated time
    double t = 0.0;
    // Integer timestep number
    int niter = 0;

    cudaMalloc((void **) &d_E, sizeof(double) * (m + 2) * (n + 2));
    cudaMalloc((void **) &d_E_prev, sizeof(double) * (m + 2) * (n + 2));
	cudaMalloc((void **) &d_R, sizeof(double) * (m + 2) * (n + 2));

    cudaMemcpy(d_E, E, sizeof(double) * (m + 2) * (n + 2), cudaMemcpyHostToDevice);
    cudaMemcpy(d_E_prev, E_prev, sizeof(double) * (m + 2) * (n + 2), cudaMemcpyHostToDevice);
	cudaMemcpy(d_R, R, sizeof(double) * (m + 2) * (n + 2), cudaMemcpyHostToDevice);

    while (t < T) {

        t += dt;
        niter++;

        simulate(d_E, d_E_prev, d_R, alpha, n, m, kk, dt, a, epsilon, M1, M2, b);

        //swap current E with previous E
        double *tmp = d_E; d_E = d_E_prev; d_E_prev = tmp;

        if (plot_freq) {
            int k = (int)(t / plot_freq);
            if ((t - k * plot_freq) < dt) {
                cudaMemcpy(E, d_E, sizeof(double) * (m + 2) * (n + 2), cudaMemcpyDeviceToHost);
                splot(E, t, niter, m + 2, n + 2);
            }
        }
    }//end of while loop

    cudaMemcpy(E_prev, d_E_prev, sizeof(double) * (m + 2) * (n + 2), cudaMemcpyDeviceToHost);

    cudaFree(d_E);
    cudaFree(d_E_prev);
    cudaFree(d_R);  

    double time_elapsed = getTime() - t0;

    double Gflops = (double)(niter * (1E-9 * n * n) * 28.0) / time_elapsed;
    double BW = (double)(niter * 1E-9 * (n * n * sizeof(double) * 4.0)) / time_elapsed;

    cout << "Number of Iterations        : " << niter << endl;
    cout << "Elapsed Time (sec)          : " << time_elapsed << endl;
    cout << "Sustained Gflops Rate       : " << Gflops << endl;
    cout << "Sustained Bandwidth (GB/sec): " << BW << endl << endl;

    double mx;
    double l2norm = stats(E_prev, m, n, &mx);
    cout << "Max: " << mx << " L2norm: " << l2norm << endl;

    if (plot_freq) {
        cout << "\n\nEnter any input to close the program and the plot..." << endl;
        getchar();
    }

    free(E);
    free(E_prev);
    free(R);

    return 0;
}

void cmdLine(int argc, char* argv[], double& T, int& n, int& bx, int& by, int& plot_freq, int& kernel) {
    /// Command line arguments
     // Default value of the domain sizes
    static struct option long_options[] = {
           {"n", required_argument, 0, 'n'},
           {"bx", required_argument, 0, 'x'},
           {"by", required_argument, 0, 'y'},
           {"tfinal", required_argument, 0, 't'},
           {"plot", required_argument, 0, 'p'},
       {"kernel_version", required_argument, 0, 'v'},
    };
    // Process command line arguments
    int ac;
    for (ac = 1;ac < argc;ac++) {
        int c;
        while ((c = getopt_long(argc, argv, "n:x:y:t:p:v:", long_options, NULL)) != -1) {
            switch (c) {

                // Size of the computational box
            case 'n':
                n = atoi(optarg);
                break;

                // X block geometry
            case 'x':
                bx = atoi(optarg);

                // Y block geometry
            case 'y':
                by = atoi(optarg);

                // Length of simulation, in simulated time units
            case 't':
                T = atof(optarg);
                break;

                // Plot the excitation variable
            case 'p':
                plot_freq = atoi(optarg);
                break;

                // Kernel version
            case 'v':
                kernel = atoi(optarg);
                break;

                // Error
            default:
                printf("Usage:  [-n <domain size>] [-t <final time >]\n\t [-p <plot frequency>]\n\t[-x <x block geometry> [-y <y block geometry][-v <Kernel Version>]\n");
                exit(-1);
            }
        }
    }
}
/* **********************************************************
 *  Author : Urvashi R.V. [04/06/2004]
 *      Modified by Didem Unat [03/23/21]
 *************************************************************/

#include <stdio.h>

 /* Function to plot the 2D array
  * 'gnuplot' is instantiated via a pipe and
  * the values to be plotted are passed through, along
  * with gnuplot commands */

FILE* gnu = NULL;

void splot(double *U, double T, int niter, int m, int n)
{
    int i, j;
    if (gnu == NULL) gnu = popen("gnuplot", "w");

    double mx = -1, mn = 32768;
    for (j = 0; j < m; j++)
        for (i = 0; i < n; i++) {
            if (U[j * m + i] > mx)
                mx = U[j * m + i];
            if (U[j * m + i] < mn)
                mn = U[j * m + i];
        }

    fprintf(gnu, "set title \"T = %f [niter = %d]\"\n", T, niter);
    fprintf(gnu, "set size square\n");
    fprintf(gnu, "set key off\n");
    fprintf(gnu, "set pm3d map\n");
    // Various color schemes
    fprintf(gnu, "set palette defined (-3 \"blue\", 0 \"white\", 1 \"red\")\n");

    //    fprintf(gnu,"set palette rgbformulae 22, 13, 31\n");
    //    fprintf(gnu,"set palette rgbformulae 30, 31, 32\n");

    fprintf(gnu, "splot [0:%d] [0:%d][%f:%f] \"-\"\n", m - 1, n - 1, mn, mx);
    for (j = 0; j < m; j++) {
        for (i = 0; i < n; i++) {
            fprintf(gnu, "%d %d %f\n", i, j, U[i * m + j]);
        }
        fprintf(gnu, "\n");
    }
    fprintf(gnu, "e\n");
    fflush(gnu);
    return;
}

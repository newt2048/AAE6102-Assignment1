# AAE6102-Assignment1
POLYU 2025 S2 AAE6102-Assignment1

# GNSS Signal Acquisition and Processing

## Task 1 — Signal Acquisition

### Objective
Process the IF data using a GNSS SDR and generate the initial acquisition results.

### GNSS Signal Acquisition Process
The GPS signal acquisition process is structured into three distinct phases: initialization, initial acquisition, and precision refinement.

#### Phase 1: Initialization
The initialization phase involves setting up the necessary parameters for signal processing. This includes determining the number of samples for a complete C/A code period, calculating the sampling interval, extracting short segments from the raw signal for initial acquisition, preparing a longer DC-removed signal segment for refinement, generating a pre-computed lookup table of satellite C/A codes, defining the frequency search range (typically in 500Hz increments), and initializing arrays to store results. These preparations establish the foundation for subsequent signal processing.

#### Phase 2: Initial Acquisition (Coarse Search)
The initial acquisition phase aims to obtain preliminary estimates of code phase and carrier frequency for each satellite's PRN code. The process involves performing FFT on each potential PRN code to obtain its frequency domain representation, then testing each frequency bin within the defined range. For each bin, a local carrier signal is generated and removed to obtain in-phase and quadrature components, which are then transformed via FFT and used for spectral domain cross-correlation. Finally, correlation peaks are identified along with corresponding code phases and frequencies. If the peak-to-average ratio exceeds a threshold, the signal is considered potentially acquired.

#### Phase 3: Precision Refinement (Fine Acquisition)
The precision refinement phase refines the frequency estimates obtained during initial acquisition. First, a longer C/A code sequence is generated using the coarse code phase estimate from the previous phase. Code modulation is removed by correlation to isolate the carrier component. Then, a high-resolution FFT (at least 8 times longer than the code sequence) is applied, precise frequency bins are calculated, and the carrier frequency is refined by locating the peak magnitude in the high-resolution spectrum. The coarse code phase from the initial search is retained as the final code phase estimate.

### Methods for Reliability and Robustness
To ensure result reliability, two main methods are employed: first, two adjacent 1-millisecond segments are selected from the received signal for simultaneous processing, with the maximum correlation coefficient taken; second, beyond identifying the maximum correlation peak, the second-largest peak is also searched for, and if the ratio between them exceeds 1.5 and they are not too close, the satellite signal is considered successfully acquired.

### Results
The test results show successful acquisition of satellites 1, 3, 11, and 18 in the urban dataset, while satellites 16, 22, 26, 27, and 31 were acquired in the open sky dataset.

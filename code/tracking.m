function [trackResults, channel]= tracking(fid, channel, settings)
% Performs code and carrier tracking for all channels.
%
%[trackResults, channel] = tracking(fid, channel, settings)
%
%   Inputs:
%       fid             - file identifier of the signal record.
%       channel         - PRN, carrier frequencies and code phases of all
%                       satellites to be tracked (prepared by preRum.m from
%                       acquisition results).
%       settings        - receiver settings.
%   Outputs:
%       trackResults    - tracking results (structure array). Contains
%                       in-phase prompt outputs and absolute spreading
%                       code's starting positions, together with other
%                       observation data from the tracking loops. All are
%                       saved every millisecond.

%--------------------------------------------------------------------------
%                           SoftGNSS v3.0
% 
% Copyright (C) Dennis M. Akos
% Written by Darius Plausinaitis and Dennis M. Akos
% Based on code by DMAkos Oct-1999
%--------------------------------------------------------------------------
%This program is free software; you can redistribute it and/or
%modify it under the terms of the GNU General Public License
%as published by the Free Software Foundation; either version 2
%of the License, or (at your option) any later version.
%
%This program is distributed in the hope that it will be useful,
%but WITHOUT ANY WARRANTY; without even the implied warranty of
%MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%GNU General Public License for more details.
%
%You should have received a copy of the GNU General Public License
%along with this program; if not, write to the Free Software
%Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
%USA.
%--------------------------------------------------------------------------

%CVS record:
%$Id: tracking.m,v 1.14.2.31 2006/08/14 11:38:22 dpl Exp $

%% Initialize result structure ============================================

% Channel status
trackResults.status         = '-';      % No tracked signal, or lost lock

% The absolute sample in the record of the C/A code start:
trackResults.absoluteSample = zeros(1, settings.msToProcess);

% Freq of the C/A code:
trackResults.codeFreq       = inf(1, settings.msToProcess);

% Frequency of the tracked carrier wave:
trackResults.carrFreq       = inf(1, settings.msToProcess);

% Outputs from the correlators (In-phase):
trackResults.I_P            = zeros(1, settings.msToProcess);
trackResults.I_E            = zeros(1, settings.msToProcess);
trackResults.I_L            = zeros(1, settings.msToProcess);

% Outputs from the correlators (Quadrature-phase):
trackResults.Q_E            = zeros(1, settings.msToProcess);
trackResults.Q_P            = zeros(1, settings.msToProcess);
trackResults.Q_L            = zeros(1, settings.msToProcess);

% Loop discriminators
trackResults.dllDiscr       = inf(1, settings.msToProcess);
trackResults.dllDiscrFilt   = inf(1, settings.msToProcess);
trackResults.pllDiscr       = inf(1, settings.msToProcess);
trackResults.pllDiscrFilt   = inf(1, settings.msToProcess);

%--- Copy initial settings for all channels -------------------------------
trackResults = repmat(trackResults, 1, settings.numberOfChannels);

%% Initialize tracking variables ==========================================

codePeriods = settings.msToProcess;     % For GPS one C/A code is one ms

%--- DLL variables --------------------------------------------------------
% Define early-late offset (in chips)
earlyLateSpc = settings.dllCorrelatorSpacing;

% Summation interval
PDIcode = 0.001;

% Calculate filter coefficient values
[tau1code, tau2code] = calcLoopCoef(settings.dllNoiseBandwidth, ...
                                    settings.dllDampingRatio, ...
                                    1.0);

%--- PLL variables --------------------------------------------------------
% Summation interval
PDIcarr = 0.001;

% Calculate filter coefficient values
[tau1carr, tau2carr] = calcLoopCoef(settings.pllNoiseBandwidth, ...
                                    settings.pllDampingRatio, ...
                                    0.25);
hwb = waitbar(0,'Tracking...');

if (settings.fileType==1)
    dataAdaptCoeff=1;
else
    dataAdaptCoeff=2;
end

%% Start processing channels ==============================================
for channelNr = 1:settings.numberOfChannels
    
    % Only process if PRN is non zero (acquisition was successful)
    if (channel(channelNr).PRN ~= 0)
        % Save additional information - each channel's tracked PRN
        trackResults(channelNr).PRN     = channel(channelNr).PRN;
        
        % Move the starting point of processing. Can be used to start the
        % signal processing at any point in the data record (e.g. for long
        % records). In addition skip through that data file to start at the
        % appropriate sample (corresponding to code phase). Assumes sample
        % type is schar (or 1 byte per sample) 
        %///@ Jr9910: 2013/04/24，这个位置为什么codePhase要减1？？？，应该和捕获程序获得的该索引有关
        %///@ Jr9910:
        %2013/04/25，跟踪程序并没有放弃使用捕获程序使用过的数据，而是每个通道找到了1ms的起点，然后进行了1ms相干积分，即读取的IF数据并不是同一时刻的数据
          fseek(fid, ...
            dataAdaptCoeff*(settings.skipNumberOfBytes + channel(channelNr).codePhase-1), ...
            'bof');


        % Get a vector with the C/A code sampled 1x/chip
        caCode = generateCAcode(channel(channelNr).PRN);
        % Then make it possible to do early and late versions
        caCode = [caCode(1023) caCode caCode(1)];

        %--- Perform various initializations ------------------------------

        % define initial code frequency basis of NCO
        codeFreq      = settings.codeFreqBasis;
        % define residual code phase (in chips)
        remCodePhase  = 0.0;
        % define carrier frequency which is used over whole tracking period
        carrFreq      = channel(channelNr).acquiredFreq;
        carrFreqBasis = channel(channelNr).acquiredFreq;
        % define residual carrier phase
        remCarrPhase  = 0.0;

        %code tracking loop parameters
        oldCodeNco   = 0.0;
        oldCodeError = 0.0;

        %carrier/Costas loop parameters
        oldCarrNco   = 0.0;
        oldCarrError = 0.0;

        %=== Process the number of specified code periods =================
        for loopCnt =  1:codePeriods
            
%% GUI update -------------------------------------------------------------
            % The GUI is updated every 50ms. This way Matlab GUI is still
            % responsive enough. At the same time Matlab is not occupied
            % all the time with GUI task.
            if (rem(loopCnt, 50) == 0)
                try
                    waitbar(loopCnt/codePeriods, ...
                            hwb, ...
                            ['Tracking: Ch ', int2str(channelNr), ...
                            ' of ', int2str(settings.numberOfChannels), ...
                            '; PRN#', int2str(channel(channelNr).PRN), ...
                            '; Completed ',int2str(loopCnt), ...
                            ' of ', int2str(codePeriods), ' msec']);                       
                catch
                    % The progress bar was closed. It is used as a signal
                    % to stop, "cancel" processing. Exit.
                    disp('Progress bar closed, exiting...');
                    return
                end
            end

%% Read next block of data ------------------------------------------------            
            % Find the size of a "block" or code period in whole samples
            
            % Update the phasestep based on code freq (variable) and
            % sampling frequency (fixed)
            %///@ Jr9910: 2013/04/15，循环变量是loopCnt，步进单位为一个CA码周期（1ms），
            % 因此以下两行代码计算一个C/A码周期内需要读出的采样点数
            %///@ Jr9910: 2013/04/15，计算一个采样点占据多少码片
            codePhaseStep = codeFreq / settings.samplingFreq;
            %///@ Jr9910：2013/04/15，计算一个C/A码周期有多少采样点
            % blksize = (码片-码片残差)/每个采样点的码片数
            blksize = ceil((settings.codeLength-remCodePhase) / codePhaseStep);
            
            % Read in the appropriate number of samples to process this
            % interation 
            [rawSignal, samplesRead] = fread(fid, ...
                dataAdaptCoeff*blksize, settings.dataType);
 
            rawSignal = rawSignal';

            if (dataAdaptCoeff==2)
                rawSignal1=rawSignal(1:2:end);
                rawSignal2=rawSignal(2:2:end);
                rawSignal = rawSignal1 + i .* rawSignal2;  %transpose vector
            end
            
            
            % If did not read in enough samples, then could be out of 
            % data - better exit 
            if (samplesRead ~= dataAdaptCoeff*blksize)
                disp('Not able to read the specified number of samples  for tracking, exiting!')
                fclose(fid);
                return
            end

%% Set up all the code phase tracking information -------------------------
            % Define index into early code vector
            tcode       = (remCodePhase-earlyLateSpc) : ...
                          codePhaseStep : ...
                          ((blksize-1)*codePhaseStep+remCodePhase-earlyLateSpc);
            %///@ Jr9910: 2013/04/24，将tcode转换成CA码表的索引，CA码表的索引为CA码片，起始为1，码片残差remCodePhase在-0.5~0.5之间，ceil后取0.
            tcode2      = ceil(tcode) + 1;
            earlyCode   = caCode(tcode2);
            
            % Define index into late code vector
            tcode       = (remCodePhase+earlyLateSpc) : ...
                          codePhaseStep : ...
                          ((blksize-1)*codePhaseStep+remCodePhase+earlyLateSpc);
            tcode2      = ceil(tcode) + 1;
            lateCode    = caCode(tcode2);
            
            % Define index into prompt code vector
            tcode       = remCodePhase : ...
                          codePhaseStep : ...
                          ((blksize-1)*codePhaseStep+remCodePhase);
            tcode2      = ceil(tcode) + 1;
            promptCode  = caCode(tcode2);
            %///@ Jr9910: 2013/04/15，码片残差，单位为码片
            remCodePhase = (tcode(blksize) + codePhaseStep) - 1023.0;

%% Generate the carrier frequency to mix the signal to baseband -----------
            time    = (0:blksize) ./ settings.samplingFreq;
            
            % Get the argument to sin/cos functions
            trigarg = ((carrFreq * 2.0 * pi) .* time) + remCarrPhase;
            remCarrPhase = rem(trigarg(blksize+1), (2 * pi));
            
            % Finally compute the signal to mix the collected data to
            % bandband
            carrsig = exp(i .* trigarg(1:blksize));

%% Generate the six standard accumulated values ---------------------------
            % First mix to baseband
            qBasebandSignal = real(carrsig .* rawSignal);
            iBasebandSignal = imag(carrsig .* rawSignal);

            % Now get early, late, and prompt values for each
            I_E = sum(earlyCode  .* iBasebandSignal);
            Q_E = sum(earlyCode  .* qBasebandSignal);
            I_P = sum(promptCode .* iBasebandSignal);
            Q_P = sum(promptCode .* qBasebandSignal);
            I_L = sum(lateCode   .* iBasebandSignal);
            Q_L = sum(lateCode   .* qBasebandSignal);
            
%% Find PLL error and update carrier NCO ----------------------------------

            % Implement carrier loop discriminator (phase detector)
            carrError = atan(Q_P / I_P) / (2.0 * pi);
            
            % Implement carrier loop filter and generate NCO command
            carrNco = oldCarrNco + (tau2carr/tau1carr) * ...
                (carrError - oldCarrError) + carrError * (PDIcarr/tau1carr);
            oldCarrNco   = carrNco;
            oldCarrError = carrError;

            % Modify carrier freq based on NCO command
            carrFreq = carrFreqBasis + carrNco;

            trackResults(channelNr).carrFreq(loopCnt) = carrFreq;

%% Find DLL error and update code NCO -------------------------------------
            codeError = (sqrt(I_E * I_E + Q_E * Q_E) - sqrt(I_L * I_L + Q_L * Q_L)) / ...
                (sqrt(I_E * I_E + Q_E * Q_E) + sqrt(I_L * I_L + Q_L * Q_L));
            
            % Implement code loop filter and generate NCO command
            codeNco = oldCodeNco + (tau2code/tau1code) * ...
                (codeError - oldCodeError) + codeError * (PDIcode/tau1code);
            oldCodeNco   = codeNco;
            oldCodeError = codeError;
            
            % Modify code freq based on NCO command
            codeFreq = settings.codeFreqBasis - codeNco;
            
            trackResults(channelNr).codeFreq(loopCnt) = codeFreq;

%% Record various measures to show in postprocessing ----------------------
            % Record sample number (based on 8bit samples)
            %///@ Jr9910:
            %2013/04/25，记录了当前ms的绝对采样点位置，实际上是每个C/A码起点在文件中所占采样点的位置
            trackResults(channelNr).absoluteSample(loopCnt) =(ftell(fid))/dataAdaptCoeff;

            trackResults(channelNr).dllDiscr(loopCnt)       = codeError;
            trackResults(channelNr).dllDiscrFilt(loopCnt)   = codeNco;
            trackResults(channelNr).pllDiscr(loopCnt)       = carrError;
            trackResults(channelNr).pllDiscrFilt(loopCnt)   = carrNco;

            trackResults(channelNr).I_E(loopCnt) = I_E;
            trackResults(channelNr).I_P(loopCnt) = I_P;
            trackResults(channelNr).I_L(loopCnt) = I_L;
            trackResults(channelNr).Q_E(loopCnt) = Q_E;
            trackResults(channelNr).Q_P(loopCnt) = Q_P;
            trackResults(channelNr).Q_L(loopCnt) = Q_L;
        end % for loopCnt

        % If we got so far, this means that the tracking was successful
        % Now we only copy status, but it can be update by a lock detector
        % if implemented
        trackResults(channelNr).status  = channel(channelNr).status;        
        
    end % if a PRN is assigned
end % for channelNr 

% Close the waitbar
close(hwb)

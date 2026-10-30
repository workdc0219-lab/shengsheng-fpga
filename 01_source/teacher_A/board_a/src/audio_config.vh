// Product clocks: 12.5MHz ADC / 100 cycles / 2 channels / 8 samples.
localparam integer AUDIO_SAMPLE_RATE_NUM = 15625;
localparam integer AUDIO_SAMPLE_RATE_DEN = 2;
localparam integer AUDIO_PITCH_Q4_ADJ = -192;
localparam integer AUDIO_CHILD_TMIN = 14, AUDIO_CHILD_TMAX = 104;
localparam integer AUDIO_TEACHER_TMIN = 16, AUDIO_TEACHER_TMAX = 101;

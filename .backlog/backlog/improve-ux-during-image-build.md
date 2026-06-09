# Improve UX during image build

Stream Docker build output to the terminal instead of swallowing it. Replace readProcessWithExitCode with callProcess (or similar) in buildImage so users see real-time progress during docker build.
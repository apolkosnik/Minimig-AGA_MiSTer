## Memories

### Test-Related Memories
- I don't want any simpler tests, fix the existing test!
- Run tests before building RBF, don't be lazy, do it right the first time! Don't waste my time, be helpful!
- I don't want to see "Let me run a basic test", do the right thing and fix the tests properly
- I don't want you to do this:"Let me run a simpler, working test instead to get actual validation results", instead fix the tests properly!
- There might be other instances of quartus running the builds, don't just pkill those, you got to keep track of your own processes!
- Keep track of the build's PID, you don't want to pkill builds from another instance!
- Create and run regression tests and correctness tests before building the rbf
- Check if the process is there with ps instead of trying to kill it right away
- Never convert the existing SOF to RBF!
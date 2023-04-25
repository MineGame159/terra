rm -f shader.spv
slangc -entry Main -target spirv -O0 -o shader.spv src/main.slang
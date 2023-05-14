rm -rf out
mkdir out

slangc -entry Main -target spirv -O0 -o out/generic.spv src/main.slang
slangc -entry Main -target spirv -O0 -o out/triangles.spv -D TRIANGLES_ONLY src/main.slang
// A small plain-C view of an FBX file read with ufbx (MIT, see ufbx-LICENSE.txt), for Swift.
// Metres, Y up, right-handed. Matrices are 16 floats, column major.
#ifndef RESET_FBX_SHIM_H
#define RESET_FBX_SHIM_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    const char *name;
    int32_t parent;        // index into nodes, -1 for the root
    int32_t is_bone;       // used by a skin, or marked as a bone in the file
    float local[16];       // node to parent
    float world[16];       // node to world, in the file's rest pose
} rs_node;

typedef struct {
    float color[4];
    const char *texture_name;   // file name the material points to, or NULL
    const void *texture_data;   // picture embedded in the FBX, or NULL
    size_t texture_size;
    uint32_t vertex_start;      // this part's triangles: vertex_start ..< vertex_start + vertex_count
    uint32_t vertex_count;
} rs_part;

typedef struct {
    int32_t node;               // the node it hangs on
    uint32_t vertex_count;      // three per triangle, not shared
    float *positions;           // 3 per vertex; a skinned mesh stands in its rest pose, in scene space
    float *normals;             // 3 per vertex
    float *uvs;                 // 2 per vertex, or NULL
    uint32_t part_count;
    rs_part *parts;
    uint32_t bone_count;        // 0 when not skinned
    int32_t *bone_nodes;        // node index per bone
    float *bone_inverse_bind;   // 16 per bone: scene space to the resting bone's space
    uint16_t *bone_indices;     // 4 per vertex
    float *bone_weights;        // 4 per vertex, adding up to 1
} rs_mesh;

typedef struct {
    void *scene;
    uint32_t node_count;
    rs_node *nodes;
    uint32_t mesh_count;
    rs_mesh *meshes;
    char error[256];
} rs_scene;

// Never NULL. On failure node_count is 0 and error says why.
rs_scene *rs_fbx_load(const char *path);
void rs_fbx_free(rs_scene *scene);

#endif

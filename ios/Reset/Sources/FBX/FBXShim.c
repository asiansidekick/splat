#include "FBXShim.h"
#include "ufbx.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

static void put_matrix(float *out, const ufbx_matrix *m) {
    for (int c = 0; c < 4; c++) {
        out[c * 4 + 0] = (float)m->cols[c].x;
        out[c * 4 + 1] = (float)m->cols[c].y;
        out[c * 4 + 2] = (float)m->cols[c].z;
        out[c * 4 + 3] = c == 3 ? 1.0f : 0.0f;
    }
}

static void fill_part(rs_part *part, const ufbx_material *material) {
    part->color[0] = part->color[1] = part->color[2] = 0.7f;
    part->color[3] = 1.0f;
    if (!material) return;
    const ufbx_texture *texture = NULL;
    if (material->pbr.base_color.has_value) {
        part->color[0] = (float)material->pbr.base_color.value_vec4.x;
        part->color[1] = (float)material->pbr.base_color.value_vec4.y;
        part->color[2] = (float)material->pbr.base_color.value_vec4.z;
    } else if (material->fbx.diffuse_color.has_value) {
        part->color[0] = (float)material->fbx.diffuse_color.value_vec3.x;
        part->color[1] = (float)material->fbx.diffuse_color.value_vec3.y;
        part->color[2] = (float)material->fbx.diffuse_color.value_vec3.z;
    }
    if (material->pbr.base_color.texture) texture = material->pbr.base_color.texture;
    else if (material->fbx.diffuse_color.texture) texture = material->fbx.diffuse_color.texture;
    if (texture) {
        if (texture->relative_filename.length > 0) part->texture_name = texture->relative_filename.data;
        else if (texture->filename.length > 0) part->texture_name = texture->filename.data;
        if (texture->content.size > 0) {
            part->texture_data = texture->content.data;
            part->texture_size = texture->content.size;
        }
    }
}

static int build_mesh(rs_mesh *out, const ufbx_mesh *mesh, const ufbx_node *node) {
    out->node = (int32_t)node->typed_id;
    size_t triangles = 0;
    for (size_t p = 0; p < mesh->material_parts.count; p++) triangles += mesh->material_parts.data[p].num_triangles;
    if (triangles == 0) return 0;
    size_t count = triangles * 3;
    const ufbx_skin_deformer *skin = mesh->skin_deformers.count > 0 ? mesh->skin_deformers.data[0] : NULL;
    if (skin && (skin->clusters.count == 0 || skin->clusters.count > 65535)) skin = NULL;

    out->positions = (float *)calloc(count * 3, sizeof(float));
    out->normals = (float *)calloc(count * 3, sizeof(float));
    if (mesh->vertex_uv.exists) out->uvs = (float *)calloc(count * 2, sizeof(float));
    out->parts = (rs_part *)calloc(mesh->material_parts.count, sizeof(rs_part));
    size_t scratch_count = mesh->max_face_triangles * 3;
    uint32_t *scratch = (uint32_t *)calloc(scratch_count ? scratch_count : 3, sizeof(uint32_t));
    if (skin) {
        out->bone_count = (uint32_t)skin->clusters.count;
        out->bone_nodes = (int32_t *)calloc(out->bone_count, sizeof(int32_t));
        out->bone_inverse_bind = (float *)calloc(out->bone_count * 16, sizeof(float));
        out->bone_indices = (uint16_t *)calloc(count * 4, sizeof(uint16_t));
        out->bone_weights = (float *)calloc(count * 4, sizeof(float));
        for (size_t c = 0; c < skin->clusters.count; c++) {
            const ufbx_skin_cluster *cluster = skin->clusters.data[c];
            out->bone_nodes[c] = cluster->bone_node ? (int32_t)cluster->bone_node->typed_id : -1;
            put_matrix(out->bone_inverse_bind + c * 16, &cluster->geometry_to_bone);
        }
    }

    size_t v = 0;
    for (size_t p = 0; p < mesh->material_parts.count; p++) {
        const ufbx_mesh_part *part = &mesh->material_parts.data[p];
        rs_part *made = &out->parts[out->part_count];
        const ufbx_material *material = NULL;
        if (part->index < mesh->materials.count) material = mesh->materials.data[part->index];
        else if (part->index < node->materials.count) material = node->materials.data[part->index];
        fill_part(made, material);
        made->vertex_start = (uint32_t)v;
        for (size_t f = 0; f < part->face_indices.count; f++) {
            ufbx_face face = mesh->faces.data[part->face_indices.data[f]];
            if (face.num_indices < 3) continue;
            uint32_t made_triangles = ufbx_triangulate_face(scratch, scratch_count, mesh, face);
            for (uint32_t i = 0; i < made_triangles * 3 && v < count; i++, v++) {
                uint32_t ix = scratch[i];
                ufbx_vec3 position = ufbx_get_vertex_vec3(&mesh->vertex_position, ix);
                out->positions[v * 3 + 0] = (float)position.x;
                out->positions[v * 3 + 1] = (float)position.y;
                out->positions[v * 3 + 2] = (float)position.z;
                if (mesh->vertex_normal.exists) {
                    ufbx_vec3 normal = ufbx_get_vertex_vec3(&mesh->vertex_normal, ix);
                    out->normals[v * 3 + 0] = (float)normal.x;
                    out->normals[v * 3 + 1] = (float)normal.y;
                    out->normals[v * 3 + 2] = (float)normal.z;
                } else {
                    out->normals[v * 3 + 1] = 1.0f;
                }
                if (out->uvs) {
                    ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, ix);
                    out->uvs[v * 2 + 0] = (float)uv.x;
                    out->uvs[v * 2 + 1] = 1.0f - (float)uv.y;   // SceneKit's pictures start at the top
                }
                if (skin) {
                    uint32_t vertex = mesh->vertex_indices.data[ix];
                    float total = 0.0f;
                    if (vertex < skin->vertices.count) {
                        ufbx_skin_vertex sv = skin->vertices.data[vertex];
                        uint32_t n = sv.num_weights < 4 ? sv.num_weights : 4;
                        for (uint32_t w = 0; w < n; w++) {
                            ufbx_skin_weight weight = skin->weights.data[sv.weight_begin + w];
                            out->bone_indices[v * 4 + w] = (uint16_t)weight.cluster_index;
                            out->bone_weights[v * 4 + w] = (float)weight.weight;
                            total += (float)weight.weight;
                        }
                    }
                    if (total > 1e-6f) {
                        for (int w = 0; w < 4; w++) out->bone_weights[v * 4 + w] /= total;
                    } else {
                        out->bone_weights[v * 4] = 1.0f;   // a loose vertex follows the first bone
                    }
                }
            }
        }
        made->vertex_count = (uint32_t)v - made->vertex_start;
        if (made->vertex_count > 0) out->part_count++;
    }
    out->vertex_count = (uint32_t)v;
    if (skin) {
        // Stand the skin in the file's rest pose, in the scene's own space, so its size and place are right
        // before any bone moves; each bone's bind is then simply where that bone rests.
        ufbx_matrix *rest = (ufbx_matrix *)calloc(skin->clusters.count, sizeof(ufbx_matrix));
        for (size_t c = 0; c < skin->clusters.count; c++) {
            const ufbx_skin_cluster *cluster = skin->clusters.data[c];
            ufbx_matrix world = cluster->bone_node ? cluster->bone_node->node_to_world : ufbx_identity_matrix;
            rest[c] = ufbx_matrix_mul(&world, &cluster->geometry_to_bone);
            ufbx_matrix inverse = ufbx_matrix_invert(&world);
            put_matrix(out->bone_inverse_bind + c * 16, &inverse);
        }
        for (size_t i = 0; i < v; i++) {
            ufbx_vec3 p = { out->positions[i * 3], out->positions[i * 3 + 1], out->positions[i * 3 + 2] };
            ufbx_vec3 n = { out->normals[i * 3], out->normals[i * 3 + 1], out->normals[i * 3 + 2] };
            double px = 0, py = 0, pz = 0, nx = 0, ny = 0, nz = 0;
            for (int w = 0; w < 4; w++) {
                float weight = out->bone_weights[i * 4 + w];
                if (weight <= 0.0f) continue;
                const ufbx_matrix *m = &rest[out->bone_indices[i * 4 + w]];
                ufbx_vec3 q = ufbx_transform_position(m, p);
                ufbx_vec3 d = ufbx_transform_direction(m, n);
                px += weight * q.x; py += weight * q.y; pz += weight * q.z;
                nx += weight * d.x; ny += weight * d.y; nz += weight * d.z;
            }
            double length = sqrt(nx * nx + ny * ny + nz * nz);
            if (length < 1e-9) { nx = 0; ny = 1; nz = 0; length = 1; }
            out->positions[i * 3] = (float)px; out->positions[i * 3 + 1] = (float)py; out->positions[i * 3 + 2] = (float)pz;
            out->normals[i * 3] = (float)(nx / length); out->normals[i * 3 + 1] = (float)(ny / length); out->normals[i * 3 + 2] = (float)(nz / length);
        }
        free(rest);
    }
    free(scratch);
    return v > 0;
}

rs_scene *rs_fbx_load(const char *path) {
    rs_scene *out = (rs_scene *)calloc(1, sizeof(rs_scene));
    ufbx_load_opts opts = { 0 };
    opts.target_axes = ufbx_axes_right_handed_y_up;
    opts.target_unit_meters = 1.0f;
    opts.space_conversion = UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY;
    opts.geometry_transform_handling = UFBX_GEOMETRY_TRANSFORM_HANDLING_MODIFY_GEOMETRY;
    opts.generate_missing_normals = true;
    ufbx_error error;
    ufbx_scene *scene = ufbx_load_file(path, &opts, &error);
    if (!scene) {
        snprintf(out->error, sizeof(out->error), "%s", error.description.data ? error.description.data : "could not read the file");
        return out;
    }
    out->scene = scene;
    out->node_count = (uint32_t)scene->nodes.count;
    out->nodes = (rs_node *)calloc(scene->nodes.count ? scene->nodes.count : 1, sizeof(rs_node));
    for (size_t i = 0; i < scene->nodes.count; i++) {
        const ufbx_node *node = scene->nodes.data[i];
        rs_node *made = &out->nodes[i];
        made->name = node->name.data ? node->name.data : "";
        made->parent = node->parent ? (int32_t)node->parent->typed_id : -1;
        made->is_bone = node->bone != NULL;
        put_matrix(made->local, &node->node_to_parent);
        put_matrix(made->world, &node->node_to_world);
    }
    size_t instances = 0;
    for (size_t m = 0; m < scene->meshes.count; m++) instances += scene->meshes.data[m]->instances.count;
    out->meshes = (rs_mesh *)calloc(instances ? instances : 1, sizeof(rs_mesh));
    for (size_t m = 0; m < scene->meshes.count; m++) {
        const ufbx_mesh *mesh = scene->meshes.data[m];
        for (size_t i = 0; i < mesh->instances.count; i++) {
            rs_mesh *made = &out->meshes[out->mesh_count];
            if (build_mesh(made, mesh, mesh->instances.data[i])) {
                for (uint32_t b = 0; b < made->bone_count; b++) {
                    int32_t bone = made->bone_nodes[b];
                    if (bone >= 0 && (uint32_t)bone < out->node_count) out->nodes[bone].is_bone = 1;
                }
                out->mesh_count++;
            }
        }
    }
    if (out->mesh_count == 0) snprintf(out->error, sizeof(out->error), "the file has no shapes in it");
    return out;
}

void rs_fbx_free(rs_scene *scene) {
    if (!scene) return;
    for (uint32_t m = 0; m < scene->mesh_count; m++) {
        rs_mesh *mesh = &scene->meshes[m];
        free(mesh->positions); free(mesh->normals); free(mesh->uvs); free(mesh->parts);
        free(mesh->bone_nodes); free(mesh->bone_inverse_bind); free(mesh->bone_indices); free(mesh->bone_weights);
    }
    free(scene->meshes);
    free(scene->nodes);
    if (scene->scene) ufbx_free_scene((ufbx_scene *)scene->scene);
    free(scene);
}

using NearestNeighbors
using DataFrames
using ProgressMeter

import Distributions
import StatsBase
import MultivariateStats

"""
    estimate_gene_probs_given_single_transcript(cm, n_molecules_per_cell)

Compute probabilities of gene expression given expression of a transcript: p(g_i | t_k) = P[i, k]
"""
function estimate_gene_probs_given_single_transcript(cm::Array{Float64, 2}, n_molecules_per_cell::Array{Int, 1})::Array{Float64, 2}
    prior_cell_probs = n_molecules_per_cell ./ sum(n_molecules_per_cell);
    probs = Array{Float64, 1}[]

    for t in 1:size(cm, 1)
        prior_transcript_probs = cm[t,:] .* prior_cell_probs;
        push!(probs, [sum(cm[g,:] .* prior_transcript_probs) for g in 1:size(cm, 1)] ./ sum(prior_transcript_probs))
    end

    return hcat(probs...)
end

function extract_gene_matrix_from_distributions(components::Array{Component, 1}, n_genes::Int)::Array{Float64, 2}
    counts_per_cell = [counts(c.composition_params) for c in components];
    for i in 1:size(counts_per_cell, 1)
        n_genes_cur = size(counts_per_cell[i], 1)
        if n_genes_cur < n_genes
            append!(counts_per_cell[i], zeros(n_genes - n_genes_cur))
        end
    end

    count_matrix = hcat(counts_per_cell...);
    return count_matrix ./ sum(count_matrix, dims=1);
end

function knn_by_expression(count_matrix::Array{T, 2} where T <: Real, n_molecules_per_cell::Array{Int, 1};
                           k::Int=15, min_molecules_per_cell::Int=10, n_prin_comps::Int=0)::Array{Array{Int, 1}, 1}
    count_matrix_norm = count_matrix ./ sum(count_matrix, dims=1)
    neighborhood_matrix = count_matrix_norm
    if n_prin_comps > 0
        pca = MultivariateStats.fit(MultivariateStats.PCA, count_matrix_norm; maxoutdim=n_prin_comps);
        neighborhood_matrix = MultivariateStats.transform(pca, count_matrix_norm)
    end

    if maximum(n_molecules_per_cell) < min_molecules_per_cell
        @warn "No cells pass min_molecules threshold ($min_molecules_per_cell). Resetting it to 1"
        min_molecules_per_cell = 1
    end

    real_cell_inds = findall(n_molecules_per_cell .>= min_molecules_per_cell);

    if length(real_cell_inds) < k
        @warn "Number of large cells ($(length(real_cell_inds))) is lower than the requested number of nearest neighbors ($k)"
        k = length(real_cell_inds)
    end

    # neighb_inds = knn(KDTree(neighborhood_matrix[:, real_cell_inds]), neighborhood_matrix, k, true)[1]
    kd_tree = KDTree(neighborhood_matrix[:, real_cell_inds]);
    neighb_inds = vcat(pmap(inds -> knn(kd_tree, neighborhood_matrix[:,inds], k, true)[1], split(1:length(real_cell_inds), n_parts=nprocs()))...)
    # neighb_inds = Array{Array{Array{Int, 1}, 1}, 1}(undef, Threads.nthreads());
    # splitted_inds = split(1:size(neighborhood_matrix, 2), n_parts=length(neighb_inds));
    # @threads for i in 1:length(splitted_inds)
    #     neighb_inds[i] = knn(kd_tree, neighborhood_matrix[:,splitted_inds[i]], k, true)[1]
    # end
    # neighb_inds = vcat(neighb_inds...);

    return [real_cell_inds[inds] for inds in neighb_inds]
end

function update_gene_count_priors!(components::Array{Component, 1}, neighb_inds::Array{Array{Int, 1}, 1})
    for (comp_dst, inds) in zip(components, neighb_inds)
        comp_dst.gene_count_prior .= 0
        for comp_src in components[inds]
            comp_dst.gene_count_prior .+= counts(comp_src.composition_params)
        end
    end
end

function smooth_size_prior_knn!(components::Array{Component, 1}, neighb_inds::Array{Array{Int, 1}, 1})
    sizes_per_cell = [hcat(eigen_values.(components[inds])...) for inds in neighb_inds];
    mean_sizes_per_cell = [vec(mapslices(trim_mean, sizes, dims=2)) for sizes in sizes_per_cell];

    for (prior_means, c) in zip(mean_sizes_per_cell, components)
        set_shape_prior!(c, prior_means)
    end
end

function smooth_size_prior_global!(bm_data_arr::Array{BmmData, 1}; set_individual_priors::Bool=false)
    sizes_per_cell = hcat(vcat([eigen_values(bm_data.components) for bm_data in bm_data_arr]...)...)
    n_mols_per_cell = vcat(num_of_molecules_per_cell.(bm_data_arr)...)

    n_min, n_max = minimum(n_mols_per_cell), maximum(n_mols_per_cell)
    threshold = 0.01 * (n_max - n_min)
    mean_prior = vec(median(sizes_per_cell[:, (n_mols_per_cell .>= (threshold + n_min)) .& (n_mols_per_cell .<= (threshold + n_max))], dims=2))

    for bm_data in bm_data_arr
        set_shape_prior!(bm_data.distribution_sampler, mean_prior)

        for c in vcat([bmd.components for bmd in bm_data_arr]...)
            if set_individual_priors || c.n_samples == 0
                set_shape_prior!(c, mean_prior)
            end
        end
    end

    return bm_data_arr
end

function update_gene_prior!(bmm_data_arr::Array{BmmData,1}, count_matrix::Array{Float64, 2}, n_molecules_per_cell::Array{Int, 1})
    probs = estimate_gene_probs_given_single_transcript(count_matrix, n_molecules_per_cell)
    for bm_data in bmm_data_arr
        bm_data.gene_probs_given_single_transcript = probs
    end

    return bmm_data_arr
end

function update_priors!(bmm_data_arr::Array{BmmData,1}; use_cell_type_size_prior::Bool, use_global_size_prior::Bool, smooth_expression::Bool,
                        min_molecules_per_cell::Int, n_prin_comps::Int)
    n_molecules_per_cell = vcat(num_of_molecules_per_cell.(bmm_data_arr)...);
    components = vcat([bm.components for bm in bmm_data_arr]...);

    components = components[n_molecules_per_cell .> 0]
    n_molecules_per_cell = n_molecules_per_cell[n_molecules_per_cell .> 0]

    count_matrix = extract_gene_matrix_from_distributions(components, maximum([maximum(ed.x[:gene]) for ed in bmm_data_arr]));

    if use_cell_type_size_prior || smooth_expression
        neighb_inds = knn_by_expression(count_matrix, n_molecules_per_cell, min_molecules_per_cell=min_molecules_per_cell, n_prin_comps=n_prin_comps)

        if use_cell_type_size_prior
            smooth_size_prior_knn!(components, neighb_inds);
        end

        if smooth_expression
            update_gene_count_priors!(components, neighb_inds);
        end
    end

    smooth_size_prior_global!(bmm_data_arr, set_individual_priors=(!use_cell_type_size_prior && use_global_size_prior))
    update_gene_prior!(bmm_data_arr, count_matrix, n_molecules_per_cell)

    return bmm_data_arr
end
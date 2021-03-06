
read_file <- function(fname) {
  readChar(fname, file.info(fname)$size)
}




all_operators = c('=', '<-', '+', '-', '*',  '/', '(','==', '!=', '&&', '||')

.are_probs_compatible_with_logical <- function(probs) {
  characters <- unlist(strsplit(probs, split=""))
  if('=' %in% characters)
    return(TRUE)
  else
    return(FALSE)
}

.model_determine_types <- function(d) {
  ddply(d, .(parent), function(d) {
    d$is_logical <- .are_probs_compatible_with_logical(d$prob)
    d
  })
}

strlen <- function (str) {
    length(strsplit(as.character(str), split = "")[[1]])
}

nmap <- function (vec, fromto, cast = I) {
	cast(map(vec, names(fromto), fromto))
}

map <- function (vec, from, to, verbose = F) {
    newVec <- vec
    for (i in 1:length(from)) {
        if (verbose) {
            print(from[i])
        }
        newVec[vec == from[i]] <- to[i]
    }
    return(newVec)
}


read_mvm <- function(fname)
{
  d <- read.table(fname, header=T, as.is=T, comment.char = "#", fill=TRUE)
  while(ncol(d) > 5) {
    d[,5] <- paste(d[,5], d[,6])
    d[,6] <- NULL
  }
  m <- as.data.frame(as.matrix(d), stringsAsFactors=FALSE)
  colnames(m) <- c('parent','_','child', 'prob', 'code')
  
  lengths <- sapply(m$prob, function(x) strlen(x))
  stopifnot(all(lengths > 0))
  
  .model_ensure_is_tree(m)
  m <- .model_determine_types(m)
  
  # make sure that there are no two different assignments ('code') on edges going to the same node,
  # and propagate assignments if necessary
  m <- ddply(m, .(child), function(m) {
    assignments <- unique(m$code)
    assignments <- setdiff(assignments, "")
    if(length(assignments) > 1)
      stop(sprintf("conflicting assignments on edges going to node %s", m$child[1]))
    if(length(assignments) == 1)
      m$code <- unlist(assignments)
    m
  })
  m
}

plot_mvm <- function(d, show_prob=TRUE, show_code=FALSE, fname_dot=NULL, start_xdot=FALSE) {
  node_ids <- unique(c(d$parent, d$child))
  p <- new("graphNEL", nodes=node_ids, edgemode="directed")
  p <- with(d, addEdge(parent, child, p, 0))
  
  edge_attrs <- list()
  d$code <- gsub(';', ' ]\n[ ', d$code)
  if(show_prob && show_code) {
    edge_attrs$label <- with(d, ifelse(code==" ", prob, sprintf("%s\n [ %s ]", prob, code)))
  } else if(show_code)
    edge_attrs$label <- d$code
  else
    edge_attrs$label <- d$prob
  names(edge_attrs$label) <-  with(d, paste(parent,child,sep='~')) # edgeNames(p, recipEdges="distinct")
  edge_attrs$fontsize <- rep(12, length(edge_attrs$label))
  names(edge_attrs$fontsize) <- edgeNames(p, recipEdges="distinct")
  
  node_types <- unique(d[,c('parent','is_logical')])
  node_attrs <- list()
  node_attrs$shape <- ifelse(node_types$is_logical, "box", "circle")
  names(node_attrs$shape) <- node_types$parent
  
  if(is.null(fname_dot))
    plot(p, nodeAttrs=node_attrs, edgeAttrs=edge_attrs, attrs=list())
  else {
    Rgraphviz::toDot(p, filename=fname_dot, nodeAttrs=node_attrs, edgeAttrs=edge_attrs, attrs=list())
    if(start_xdot)
      system(sprintf("xdot %s &", fname_dot))
  }
}

# TODO: Make sure that the variable of interest occurs on both sides (right and left) in the random effect specifications

mvm_generate_code <- function(m, par_vars, iv_vars, dv_vars, logLik, raneff, file=NULL, ignore_vars = NULL)
{
  ### prepare 'model' section
  model_yield <- .model_harvest_code(m)
  model_yield <- .model_reshape_code(model_yield)
  
  # TODO: rename 'code' column to 'assignmens'
  branch_conditions = lapply(model_yield$condition, function(condition) as.list(parse(text=condition))) # remove processing of conditions at this point
  branch_cprob = lapply(model_yield$prob, function(code) as.list(parse(text=code)))
  branch_code = lapply(model_yield$code, function(code) as.list(parse(text=code)))

  # check variable consistency
  vars = .check_variables(branch_conditions, branch_cprob, branch_code, par_vars, iv_vars, dv_vars, logLik, raneff, ignore_vars = ignore_vars)

  add_indices <- function(code) .append_to_symbol(code, vars$data, '[i_obs]')
  substitute_transformed_vars <- function(code) .modify_symbol(code, names(raneff), sprintf('cur_%s', names(raneff)))
  
  # add indices to all vector variables
  model_yield$condition <- add_indices(model_yield$condition)
  model_yield$prob <- add_indices(model_yield$prob)  %>%  substitute_transformed_vars
  model_yield$code <- add_indices(model_yield$code)  %>%  substitute_transformed_vars
  
  raneff <- add_indices(raneff)
  #print(raneff)
  
  logLik <- .append_to_symbol(logLik, vars$data, '[i_obs]') %>% paste0
  
  # declare variables needed for parameters affected by random effects
  raneff_types <- sapply(names(raneff), function(par_name) ifelse(par_name %in% names(par_vars), par_vars[par_name], 'real'))
  raneff_affected_vars <- sprintf("real cur_%s", names(raneff_types));  
  raneff_grouping_vars <- unique(unlist(vars$ran_eff))
  raneff_indices <- sprintf("int cur_%s", raneff_grouping_vars);
  raneff_declarations <- c(raneff_affected_vars, raneff_indices)
  
  ### create model loop
  model_loop_header <- sprintf("real logLik[%d] = logLikInit", nrow(model_yield))
  blocks <- llply(1:nrow(model_yield), function(idx)
  {
    # include path name as a comment
    header_path <- sprintf("\n// path: %s", model_yield$id[idx])
    
    # determine path probability
    if (model_yield$prob[idx] != "") {
        prob <- sprintf("logProb_path = log(%s)", model_yield$prob[idx])
    } else {
        prob <- "logProb_path = 0" # set probability to 1, if only conditions and no probabilities were specified (corresponds to log(p) = 0)
    }
    
    # TODO: Ensure that all variable names in vars$lhs are defined for every branch at this point. 
    if (model_yield$code[idx] == "") {
        msg <- sprintf("No assignments defined on this branch: %s.", model_yield$id[idx]);
        stop(msg)
    }
    assignments <- model_yield$code[idx] %>% gsub(";[ \t]*", ";", .) %>% strsplit(., split=";")
    assign_logLik <- sprintf("logLik[%d] = logProb_path + %s", idx, paste(logLik, collapse=" + ") )

    path_lines <- .format_lines( c(header_path, prob, assignments, assign_logLik) )
    path_block <- paste(path_lines, collapse="\n")
    
    # encode path conditions (logical variables are moved here instead of being included in the path probability)
    if (model_yield$condition[idx] != "") {
        condition <- sprintf("if (%s)", model_yield$condition[idx])
        path_block %<>% .format_block(condition, .)
    }
    
    path_block
  })
  
  incr_logLik <- "\ntarget += log_sum_exp(logLik)"
  # condition <- sprintf("if(%s)", m$condition[1])

  model_lines <- .format_lines( c(model_loop_header, unlist(blocks), incr_logLik) )
  model_loop_body <- paste(model_lines, collapse="\n")

  # declare variables needed for parameters affected by random effects
  raneff_definitions_indices <- sprintf("cur_%s = %s[i_obs]", raneff_grouping_vars, raneff_grouping_vars);
  
  raneff <- sapply(names(vars$ran_eff), function(parname) {
    .modify_symbol(raneff[[parname]], vars$ran_eff[[parname]], sprintf('%s_%s[cur_%s]', parname, vars$ran_eff[[parname]], vars$ran_eff[[parname]] ))
  })
  
  raneff_definitions_vars <- sprintf("cur_%s = %s", names(raneff), raneff);
  raneff_definitions <- c(raneff_definitions_indices, raneff_definitions_vars)
  
  # format the for loop block
  model_loop_body <- .format_block('for(i_obs in 1:n_obs)', c(raneff_definitions, model_loop_body))
  
  hyperpar_likelihood_lines <- .generate_code_likHyperpar(vars$ran_eff)
  
  # create model header
  model_logLikInit <- sprintf("real logLikInit[%d] = {%s}", nrow(model_yield), rep("log(0)", nrow(model_yield)) %>% paste(collapse = ","))
  model_header_lines <- c('int i', 'real logProb_path', model_logLikInit, sprintf("real %s", vars$lhs), raneff_declarations)

  # format the entire model block
  code_section_model <- .format_block('model', c(model_header_lines, model_loop_body, hyperpar_likelihood_lines))  
    
  ####### prepare 'data' section
  raneff_n_vars <- sprintf("n_%s", raneff_grouping_vars)
  raneff_data_vars <- sprintf('int<lower=1,upper=n_%s>', raneff_grouping_vars);
  names(raneff_data_vars) <- raneff_grouping_vars
  code_section_data <- .generate_code_data(data_vars=c(iv_vars, dv_vars, raneff_data_vars), n_vars=c('n_obs', raneff_n_vars), 'n_obs')
    
  ####### prepare 'parameters' section
  code_section_par <- .generate_code_par(par_vars, vars$ran_eff)
  
  # merge all blocks
  code <- paste(code_section_data, code_section_par, code_section_model, sep="\n")
  code <- gsub(";([^\n])", ";\n\\1", code)

  if(!is.null(file)) {
    cat(code, file=file)
  }
  invisible(code)  
}

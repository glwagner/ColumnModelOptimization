

## Utils for writing to output

function saveplot(params, name, nll)
        p = visualize_realizations(nll.model, nll.data, 1:180:length(nll.data), params)
        PyPlot.savefig(directory*name*".png")
end

function open_output_file(directory)
        isdir(directory) || mkpath(directory)
        file = directory*"output.txt"
        touch(file)
        o = open(file, "w")
        return o
end

function writeout(o, name, nll, params)
        param_vect = [params...]
        loss_value = nll(params)
        write(o, "----------- \n")
        write(o, "$(name) \n")
        write(o, "Parameters: $(param_vect) \n")
        write(o, "Loss: $(loss_value) \n")
        saveplot(params, name, nll)
end
